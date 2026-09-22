import Foundation

public struct OFXParser: Sendable {
    public static let version = "ofx-1.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        guard [.ofx, .qfx, .qbo].contains(replay.format) else { throw EngineError.unsupportedFormat(replay.format) }
        guard replay.parserVersion == Self.version else {
            throw EngineError.invalidConfiguration("unsupported OFX parser version: \(replay.parserVersion)")
        }
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("OFX bytes") }
        let decoded = try decode(data)
        let root = decoded.isXML
            ? try BoundedXMLTree.parse(Data(decoded.body.utf8), limits: limits)
            : try parseSGML(decoded.body)
        guard root.name.uppercased() == "OFX" else { throw EngineError.malformedInput("OFX root element is missing") }
        let statements = root.descendants(named: "STMTRS") + root.descendants(named: "CCSTMTRS")
        guard !statements.isEmpty else { throw EngineError.malformedInput("OFX has no complete bank or card statement envelope") }

        let identity = SourceIdentity(data: data)
        var transactions: [CanonicalTransaction] = []
        var balances: [StatementBalance] = []
        var warnings: [String] = []
        var completeness: SourceCompleteness = .complete

        for (statementIndex, statement) in statements.enumerated() {
            let account = try accountID(statement, profile: replay.structuredProfile)
            let currencyRaw = try requiredText(statement, "CURDEF", fallback: replay.structuredProfile?.defaultCurrency)
            let currency = try CurrencyCode(currencyRaw)
            guard let list = statement.descendants(named: "BANKTRANLIST").first else {
                throw EngineError.malformedInput("OFX statement lacks BANKTRANLIST")
            }
            if let startText = list.first(named: "DTSTART")?.text, let endText = list.first(named: "DTEND")?.text {
                let coverageStart = try StructuredValueParser.ofxDate(startText)
                let coverageEnd = try StructuredValueParser.ofxDate(endText)
                guard coverageStart <= coverageEnd else { throw EngineError.malformedInput("OFX statement period is reversed") }
                if coverageStart > period.start || coverageEnd < period.end {
                    completeness = .incomplete
                    warnings.append("OFX statement coverage does not include the full selected period for account \(account)")
                }
            } else {
                completeness = .incomplete
                warnings.append("OFX statement period is incomplete for account \(account)")
            }
            for (recordIndex, record) in list.children(named: "STMTTRN").enumerated() {
                let amountRaw = try requiredText(record, "TRNAMT")
                let dateRaw = try requiredText(record, "DTPOSTED")
                let date = try StructuredValueParser.ofxDate(dateRaw)
                guard period.contains(date) else {
                    throw EngineError.periodViolation("OFX transaction \(statementIndex + 1):\(recordIndex + 1) is outside the selected period")
                }
                let amount = try StructuredValueParser.exactISOAmount(amountRaw)
                let fields = Dictionary(uniqueKeysWithValues: record.children.enumerated().map {
                    ("\($0.element.name):\($0.offset)", $0.element.recursiveText)
                })
                transactions.append(CanonicalTransaction(
                    sourceID: identity.sourceID,
                    locator: "statement:\(statementIndex + 1)/transaction:\(recordIndex + 1)",
                    sourceOrdinal: transactions.count,
                    account: account,
                    currency: currency,
                    bookingDate: date,
                    amount: amount,
                    strongID: optionalText(record, "FITID"),
                    reference: optionalText(record, "REFNUM") ?? optionalText(record, "CHECKNUM"),
                    payee: optionalText(record, "NAME"),
                    description: optionalText(record, "MEMO"),
                    memo: optionalText(record, "MEMO"),
                    transactionCode: optionalText(record, "TRNTYPE"),
                    originalValues: fields
                ))
                guard transactions.count <= limits.maximumRecords else { throw EngineError.resourceLimit("OFX transaction records") }
            }
            if let ledger = statement.descendants(named: "LEDGERBAL").first {
                let amount = try StructuredValueParser.exactISOAmount(try requiredText(ledger, "BALAMT"))
                let date = try StructuredValueParser.ofxDate(try requiredText(ledger, "DTASOF"))
                guard period.contains(date) else { throw EngineError.periodViolation("OFX ledger balance is outside the selected period") }
                balances.append(StatementBalance(
                    kind: .closing, account: account, currency: currency, date: date,
                    amount: amount, locator: "statement:\(statementIndex + 1)/ledger-balance"
                ))
            }
        }
        return SourceStatement(
            role: role,
            file: identity.proof(filename: filename, byteCount: data.count),
            replay: replay,
            period: period,
            transactions: transactions,
            balances: balances + replay.balanceOverrides,
            completeness: completeness,
            warnings: warnings.sorted()
        )
    }

    private struct DecodedOFX {
        let body: String
        let isXML: Bool
    }

    private func decode(_ data: Data) throws -> DecodedOFX {
        guard let latin = String(data: data, encoding: .isoLatin1),
              let rootRange = latin.range(of: "<OFX", options: [.caseInsensitive]) else {
            throw EngineError.malformedInput("OFX body is missing")
        }
        let header = String(latin[..<rootRange.lowerBound])
        let upperHeader = header.uppercased()
        let encoding: String.Encoding
        if upperHeader.contains("ENCODING:UTF-8") || upperHeader.contains("ENCODING:UTF8") || upperHeader.contains("ENCODING=\"UTF-8\"") {
            encoding = .utf8
        } else if upperHeader.contains("ENCODING:USASCII") || upperHeader.contains("ENCODING:ASCII") || header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            encoding = .ascii
        } else if upperHeader.contains("ENCODING:1252") || upperHeader.contains("ENCODING:WINDOWS-1252") {
            encoding = .windowsCP1252
        } else {
            throw EngineError.malformedInput("unsupported OFX character encoding")
        }
        let byteOffset = latin.utf8.distance(from: latin.utf8.startIndex, to: rootRange.lowerBound.samePosition(in: latin.utf8) ?? latin.utf8.startIndex)
        guard byteOffset >= 0, byteOffset <= data.count,
              let body = String(data: data.subdata(in: byteOffset..<data.count), encoding: encoding) else {
            throw EngineError.malformedInput("OFX text cannot be decoded")
        }
        let xmlVersion = upperHeader.contains("VERSION:2") || upperHeader.contains("OFXSGML=\"2") || body.contains("</STMTTRN>")
        return DecodedOFX(body: body, isXML: xmlVersion)
    }

    private func parseSGML(_ text: String) throws -> BoundedXMLNode {
        let containers: Set<String> = [
            "OFX", "SIGNONMSGSRSV1", "SONRS", "STATUS", "BANKMSGSRSV1", "STMTTRNRS", "STMTRS",
            "BANKACCTFROM", "BANKTRANLIST", "STMTTRN", "LEDGERBAL", "AVAILBAL",
            "CREDITCARDMSGSRSV1", "CCSTMTTRNRS", "CCSTMTRS", "CCACCTFROM", "CCBANKTRANLIST"
        ]
        var stack: [BoundedXMLNode] = []
        var root: BoundedXMLNode?
        var cursor = text.startIndex
        var nodeCount = 0

        while let open = text[cursor...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { throw EngineError.malformedInput("unterminated OFX SGML tag") }
            let rawTag = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTag.isEmpty, !rawTag.hasPrefix("!") && !rawTag.hasPrefix("?") else {
                throw EngineError.malformedInput("unsupported OFX SGML declaration")
            }
            let closing = rawTag.hasPrefix("/")
            let tag = (closing ? String(rawTag.dropFirst()) : rawTag).uppercased()
            guard tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                throw EngineError.malformedInput("invalid OFX SGML tag")
            }
            if closing {
                guard stack.last?.name == tag else { throw EngineError.malformedInput("OFX SGML container nesting is invalid") }
                stack.removeLast()
                cursor = text.index(after: close)
                continue
            }

            nodeCount += 1
            guard nodeCount <= limits.maximumXMLNodes else { throw EngineError.resourceLimit("OFX SGML nodes") }
            let node = BoundedXMLNode(name: tag, namespaceURI: nil, attributes: [:])
            if let parent = stack.last { parent.children.append(node) }
            else if root == nil { root = node }
            else { throw EngineError.malformedInput("OFX SGML has multiple roots") }

            let afterTag = text.index(after: close)
            if containers.contains(tag) {
                stack.append(node)
                guard stack.count <= limits.maximumXMLDepth else { throw EngineError.resourceLimit("OFX SGML depth") }
                cursor = afterTag
            } else {
                let nextOpen = text[afterTag...].firstIndex(of: "<") ?? text.endIndex
                let rawValue = String(text[afterTag..<nextOpen]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawValue.utf8.count <= limits.maximumFieldBytes else { throw EngineError.resourceLimit("OFX field bytes") }
                node.textFragments = [try decodeEntities(rawValue)]
                cursor = nextOpen
                if nextOpen < text.endIndex,
                   text[nextOpen...].uppercased().hasPrefix("</\(tag)>") {
                    cursor = text.index(nextOpen, offsetBy: tag.count + 3)
                }
            }
        }
        guard stack.isEmpty, let root else { throw EngineError.malformedInput("OFX SGML container is truncated") }
        return root
    }

    private func decodeEntities(_ raw: String) throws -> String {
        var output = ""
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard raw[cursor] == "&" else { output.append(raw[cursor]); cursor = raw.index(after: cursor); continue }
            guard let semicolon = raw[cursor...].firstIndex(of: ";") else { throw EngineError.malformedInput("unterminated OFX entity") }
            let token = String(raw[raw.index(after: cursor)..<semicolon])
            let scalar: UnicodeScalar?
            switch token.lowercased() {
            case "amp": scalar = "&".unicodeScalars.first
            case "lt": scalar = "<".unicodeScalars.first
            case "gt": scalar = ">".unicodeScalars.first
            case "quot": scalar = "\"".unicodeScalars.first
            case "apos": scalar = "'".unicodeScalars.first
            default:
                if token.hasPrefix("#x"), let value = UInt32(token.dropFirst(2), radix: 16) { scalar = UnicodeScalar(value) }
                else if token.hasPrefix("#"), let value = UInt32(token.dropFirst()) { scalar = UnicodeScalar(value) }
                else { scalar = nil }
            }
            guard let scalar else { throw EngineError.malformedInput("unsupported OFX entity") }
            output.unicodeScalars.append(scalar)
            cursor = raw.index(after: semicolon)
        }
        return output
    }

    private func accountID(_ statement: BoundedXMLNode, profile: StructuredImportProfile?) throws -> String {
        if let account = statement.descendants(named: "BANKACCTFROM").first?.first(named: "ACCTID")?.text,
           !account.isEmpty { return account }
        if let account = statement.descendants(named: "CCACCTFROM").first?.first(named: "ACCTID")?.text,
           !account.isEmpty { return account }
        guard let fallback = profile?.defaultAccount, !fallback.isEmpty else { throw EngineError.malformedInput("OFX account identifier is missing") }
        return fallback
    }

    private func requiredText(_ node: BoundedXMLNode, _ name: String, fallback: String? = nil) throws -> String {
        let values = node.descendants(named: name).map(\.text).filter { !$0.isEmpty }
        if values.count == 1 { return values[0] }
        if values.isEmpty, let fallback, !fallback.isEmpty { return fallback }
        throw EngineError.malformedInput(values.isEmpty ? "OFX \(name) is missing" : "OFX \(name) is duplicated")
    }

    private func optionalText(_ node: BoundedXMLNode, _ name: String) -> String? {
        let values = node.children(named: name).map(\.text).filter { !$0.isEmpty }
        return values.count == 1 ? values[0] : nil
    }
}
