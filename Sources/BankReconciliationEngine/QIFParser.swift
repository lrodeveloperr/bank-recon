import Foundation

public struct QIFParser: Sendable {
    public static let version = "qif-1.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        guard replay.format == .qif || replay.format == .qmtf else { throw EngineError.unsupportedFormat(replay.format) }
        guard replay.parserVersion == Self.version else {
            throw EngineError.invalidConfiguration("unsupported QIF parser version: \(replay.parserVersion)")
        }
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("QIF bytes") }
        guard let profile = replay.structuredProfile else { throw EngineError.invalidConfiguration("QIF requires a bound locale/account profile") }
        guard let defaultCurrency = profile.defaultCurrency, !defaultCurrency.isEmpty else {
            throw EngineError.invalidConfiguration("QIF profile requires a default currency")
        }
        let currency = try CurrencyCode(defaultCurrency)
        let decoded: String
        var warnings: [String] = []
        if let utf8 = String(data: data, encoding: .utf8) {
            decoded = utf8
        } else if let windows = String(data: data, encoding: .windowsCP1252) {
            decoded = windows
            warnings.append("QIF source was decoded as Windows-1252")
        } else {
            throw EngineError.malformedInput("QIF text encoding is unsupported")
        }
        let normalized = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { throw EngineError.malformedInput("QIF source is empty") }

        let identity = SourceIdentity(data: data)
        var section: String?
        var currentAccount = profile.defaultAccount
        var record: [(line: Int, code: Character, value: String)] = []
        var recordStart = 0
        var transactions: [CanonicalTransaction] = []

        func isTransactionSection(_ value: String?) -> Bool {
            guard let value else { return false }
            return ["BANK", "CASH", "CCARD", "OTHA", "OTHL"].contains(value.uppercased())
        }

        func finishRecord(at terminatorLine: Int) throws {
            defer { record = []; recordStart = 0 }
            guard !record.isEmpty else { return }
            guard let section else { throw EngineError.malformedInput("QIF record appears before a section header") }
            if section.uppercased() == "ACCOUNT" {
                let names = record.filter { $0.code == "N" }.map(\.value)
                guard names.count == 1, !names[0].isEmpty else { throw EngineError.malformedInput("QIF account record requires exactly one name") }
                currentAccount = names[0]
                return
            }
            guard isTransactionSection(section) else { return }
            let criticalCodes: Set<Character> = ["D", "T"]
            for code in criticalCodes where record.filter({ $0.code == code }).count != 1 {
                throw EngineError.malformedInput("QIF transaction requires exactly one \(code) field")
            }
            let dateRaw = record.first(where: { $0.code == "D" })?.value ?? ""
            let amountRaw = record.first(where: { $0.code == "T" })?.value ?? ""
            let date = try StructuredValueParser.date(dateRaw, order: profile.dateOrder)
            guard period.contains(date) else {
                throw EngineError.periodViolation("QIF record beginning on line \(recordStart) is outside the selected period")
            }
            let account = currentAccount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !account.isEmpty else { throw EngineError.malformedInput("QIF transaction has no account context") }
            let amount = try StructuredValueParser.exactAmount(amountRaw, profile: profile)
            var originals: [String: String] = [:]
            for (index, field) in record.enumerated() { originals["\(field.code):\(index)"] = field.value }
            let values: (Character) -> [String] = { code in record.filter { $0.code == code }.map(\.value) }
            transactions.append(CanonicalTransaction(
                sourceID: identity.sourceID,
                locator: "section:\(section)/record:\(transactions.count + 1)/line:\(recordStart)-\(terminatorLine)",
                sourceOrdinal: transactions.count,
                account: account,
                currency: currency,
                bookingDate: date,
                amount: amount,
                strongID: values("N").first,
                reference: values("N").first,
                payee: values("P").first,
                description: values("M").first ?? values("P").first,
                memo: values("M").first,
                clearedStatus: values("C").first,
                category: values("L").first,
                originalValues: originals
            ))
            guard transactions.count <= limits.maximumRecords else { throw EngineError.resourceLimit("QIF records") }
        }

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = lineNumber == 1 ? rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) : rawLine
            guard line.utf8.count <= limits.maximumFieldBytes else { throw EngineError.resourceLimit("QIF line bytes") }
            if line.hasPrefix("!") {
                guard record.isEmpty else { throw EngineError.malformedInput("QIF section changed before ^ record termination") }
                if line.uppercased() == "!ACCOUNT" {
                    section = "Account"
                } else if line.uppercased().hasPrefix("!TYPE:") {
                    section = String(line.dropFirst(6))
                    if section?.uppercased() == "INVST" {
                        throw EngineError.malformedInput("investment QIF records are outside the supported bank-reconciliation scope")
                    }
                } else if !line.uppercased().hasPrefix("!OPTION:") {
                    throw EngineError.malformedInput("unsupported QIF section directive: \(line)")
                }
                continue
            }
            if line == "^" {
                try finishRecord(at: lineNumber)
                continue
            }
            if line.isEmpty {
                guard record.isEmpty else { throw EngineError.malformedInput("blank line inside QIF record") }
                continue
            }
            guard section != nil, let code = line.first else { throw EngineError.malformedInput("QIF field appears before a section") }
            if record.isEmpty { recordStart = lineNumber }
            record.append((lineNumber, code, String(line.dropFirst())))
        }
        guard record.isEmpty else { throw EngineError.malformedInput("QIF final record is missing ^ termination") }
        return SourceStatement(
            role: role,
            file: identity.proof(filename: filename, byteCount: data.count),
            replay: replay,
            period: period,
            transactions: transactions,
            balances: replay.balanceOverrides,
            warnings: warnings.sorted()
        )
    }
}
