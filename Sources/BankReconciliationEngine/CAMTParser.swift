import Foundation

public struct CAMTParser: Sendable {
    public static let version = "camt-1.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        guard replay.format == .camt053 || replay.format == .camt054 else { throw EngineError.unsupportedFormat(replay.format) }
        guard replay.parserVersion == Self.version else {
            throw EngineError.invalidConfiguration("unsupported CAMT parser version: \(replay.parserVersion)")
        }
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("CAMT bytes") }
        let root = try BoundedXMLTree.parse(data, limits: limits)
        guard root.name == "Document", let namespace = root.namespaceURI else {
            throw EngineError.malformedInput("CAMT Document root or namespace is missing")
        }
        let family = replay.format == .camt053 ? "053" : "054"
        try validate(namespace: namespace, family: family)
        let envelopeName = replay.format == .camt053 ? "BkToCstmrStmt" : "BkToCstmrDbtCdtNtfctn"
        let statementName = replay.format == .camt053 ? "Stmt" : "Ntfctn"
        guard let envelope = root.first(named: envelopeName, namespace: namespace) else {
            throw EngineError.malformedInput("CAMT \(family) envelope is missing")
        }
        let statements = envelope.children(named: statementName, namespace: namespace)
        guard !statements.isEmpty else { throw EngineError.malformedInput("CAMT \(family) contains no statement/notification") }
        let identity = SourceIdentity(data: data)
        var transactions: [CanonicalTransaction] = []
        var balances: [StatementBalance] = []

        for (statementIndex, statement) in statements.enumerated() {
            let account = try accountID(statement, namespace: namespace, fallback: replay.structuredProfile?.defaultAccount)
            for (entryIndex, entry) in statement.children(named: "Ntry", namespace: namespace).enumerated() {
                let amountNode = try requiredChild(entry, "Amt", namespace: namespace)
                guard let currencyRaw = amountNode.attributes["Ccy"] ?? amountNode.attributes["ccy"] else {
                    throw EngineError.malformedInput("CAMT entry amount currency is missing")
                }
                let currency = try CurrencyCode(currencyRaw)
                let rawAmount = try StructuredValueParser.exactISOAmount(amountNode.text)
                let indicator = try requiredText(entry, "CdtDbtInd", namespace: namespace)
                let reversal = entry.first(named: "RvslInd", namespace: namespace)?.text.lowercased()
                let amount = try signed(rawAmount, indicator: indicator, reversed: reversal == "true" || reversal == "1")
                let bookingDate = try dateChoice(try requiredChild(entry, "BookgDt", namespace: namespace), namespace: namespace)
                guard period.contains(bookingDate) else {
                    throw EngineError.periodViolation("CAMT entry \(statementIndex + 1):\(entryIndex + 1) is outside the selected period")
                }
                let valueDate = try entry.first(named: "ValDt", namespace: namespace).map { try dateChoice($0, namespace: namespace) }
                let references = referenceValues(entry, namespace: namespace)
                let remittance = entry.descendants(named: "Ustrd", namespace: namespace).map(\.text).filter { !$0.isEmpty }
                let descriptionValues = ([entry.first(named: "AddtlNtryInf", namespace: namespace)?.text].compactMap { $0 } + remittance)
                    .filter { !$0.isEmpty }
                let transactionCode = entry.first(named: "BkTxCd", namespace: namespace).map {
                    $0.descendants(named: "Cd", namespace: namespace).map(\.text).filter { !$0.isEmpty }.joined(separator: "/")
                }
                var originals: [String: String] = [
                    "amount": amountNode.text,
                    "currency": currencyRaw,
                    "creditDebitIndicator": indicator,
                    "bookingDate": bookingDate.description
                ]
                if let valueDate { originals["valueDate"] = valueDate.description }
                if !references.isEmpty { originals["references"] = references.joined(separator: "|") }
                if !remittance.isEmpty { originals["remittance"] = remittance.joined(separator: "|") }
                transactions.append(CanonicalTransaction(
                    sourceID: identity.sourceID,
                    locator: "statement:\(statementIndex + 1)/entry:\(entryIndex + 1)",
                    sourceOrdinal: transactions.count,
                    account: account,
                    currency: currency,
                    bookingDate: bookingDate,
                    valueDate: valueDate,
                    amount: amount,
                    strongID: nonempty(entry.first(named: "AcctSvcrRef", namespace: namespace)?.text) ?? nonempty(entry.first(named: "NtryRef", namespace: namespace)?.text),
                    reference: references.isEmpty ? nil : references.joined(separator: " | "),
                    description: descriptionValues.isEmpty ? nil : descriptionValues.joined(separator: " | "),
                    memo: remittance.isEmpty ? nil : remittance.joined(separator: " | "),
                    transactionCode: nonempty(transactionCode),
                    clearedStatus: nonempty(entry.first(named: "Sts", namespace: namespace)?.recursiveText),
                    originalValues: originals
                ))
                guard transactions.count <= limits.maximumRecords else { throw EngineError.resourceLimit("CAMT entries") }
            }

            for (balanceIndex, balance) in statement.children(named: "Bal", namespace: namespace).enumerated() {
                guard let code = balance.path("Tp", "CdOrPrtry", "Cd", namespace: namespace)?.text,
                      code == "OPBD" || code == "CLBD" else { continue }
                let amountNode = try requiredChild(balance, "Amt", namespace: namespace)
                guard let currencyRaw = amountNode.attributes["Ccy"] ?? amountNode.attributes["ccy"] else {
                    throw EngineError.malformedInput("CAMT balance currency is missing")
                }
                let rawAmount = try StructuredValueParser.exactISOAmount(amountNode.text)
                let indicator = try requiredText(balance, "CdtDbtInd", namespace: namespace)
                let amount = try signed(rawAmount, indicator: indicator, reversed: false)
                let date = try dateChoice(try requiredChild(balance, "Dt", namespace: namespace), namespace: namespace)
                guard period.contains(date) else { throw EngineError.periodViolation("CAMT balance is outside the selected period") }
                balances.append(StatementBalance(
                    kind: code == "OPBD" ? .opening : .closing,
                    account: account,
                    currency: try CurrencyCode(currencyRaw),
                    date: date,
                    amount: amount,
                    locator: "statement:\(statementIndex + 1)/balance:\(balanceIndex + 1)/\(code)"
                ))
            }
        }
        let notification = replay.format == .camt054
        return SourceStatement(
            role: role,
            file: identity.proof(filename: filename, byteCount: data.count),
            replay: replay,
            period: period,
            transactions: transactions,
            balances: balances + replay.balanceOverrides,
            completeness: notification ? .notificationOnly : .complete,
            warnings: notification ? ["CAMT.054 is a bank notification and may not be a complete account statement"] : []
        )
    }

    private func validate(namespace: String, family: String) throws {
        let prefix = "urn:iso:std:iso:20022:tech:xsd:camt.\(family).001."
        guard namespace.hasPrefix(prefix),
              let version = Int(namespace.dropFirst(prefix.count)),
              (2...8).contains(version),
              namespace == prefix + String(format: "%02d", version) else {
            throw EngineError.malformedInput("unsupported CAMT.\(family) namespace/version")
        }
    }

    private func accountID(_ statement: BoundedXMLNode, namespace: String, fallback: String?) throws -> String {
        if let account = statement.path("Acct", "Id", "IBAN", namespace: namespace)?.text, !account.isEmpty { return account }
        if let account = statement.path("Acct", "Id", "Othr", "Id", namespace: namespace)?.text, !account.isEmpty { return account }
        if let fallback = nonempty(fallback) { return fallback }
        throw EngineError.malformedInput("CAMT account identifier is missing")
    }

    private func requiredChild(_ node: BoundedXMLNode, _ name: String, namespace: String) throws -> BoundedXMLNode {
        let values = node.children(named: name, namespace: namespace)
        guard values.count == 1 else { throw EngineError.malformedInput("CAMT \(name) must occur exactly once") }
        return values[0]
    }

    private func requiredText(_ node: BoundedXMLNode, _ name: String, namespace: String) throws -> String {
        let value = try requiredChild(node, name, namespace: namespace).text
        guard !value.isEmpty else { throw EngineError.malformedInput("CAMT \(name) is empty") }
        return value
    }

    private func dateChoice(_ node: BoundedXMLNode, namespace: String) throws -> LocalDate {
        let dates = node.children(named: "Dt", namespace: namespace) + node.children(named: "DtTm", namespace: namespace)
        if dates.count == 1 { return try StructuredValueParser.date(dates[0].text, order: .ymd) }
        if node.name == "Dt", !node.text.isEmpty { return try StructuredValueParser.date(node.text, order: .ymd) }
        throw EngineError.malformedInput("CAMT date choice must contain exactly one Dt or DtTm")
    }

    private func signed(_ amount: ExactAmount, indicator: String, reversed: Bool) throws -> ExactAmount {
        let signed: ExactAmount
        switch indicator.uppercased() {
        case "CRDT": signed = amount
        case "DBIT": signed = try ExactAmount.zero.subtracting(amount)
        default: throw EngineError.malformedInput("CAMT credit/debit indicator is invalid")
        }
        return reversed ? try ExactAmount.zero.subtracting(signed) : signed
    }

    private func referenceValues(_ entry: BoundedXMLNode, namespace: String) -> [String] {
        let names = ["EndToEndId", "MndtId", "CdtrSchmeId", "TxId", "InstrId", "PmtInfId"]
        return names.flatMap { name in entry.descendants(named: name, namespace: namespace).map(\.text) }
            .compactMap(nonempty)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
