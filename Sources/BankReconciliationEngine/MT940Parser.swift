import Foundation

public struct MT940Parser: Sendable {
    public static let version = "mt940-1.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        guard replay.format == .mt940 else { throw EngineError.unsupportedFormat(replay.format) }
        guard replay.parserVersion == Self.version else {
            throw EngineError.invalidConfiguration("unsupported MT940 parser version: \(replay.parserVersion)")
        }
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("MT940 bytes") }
        let text: String
        var warnings: [String] = []
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else if let windows = String(data: data, encoding: .windowsCP1252) {
            text = windows
            warnings.append("MT940 source was decoded as Windows-1252")
        } else { throw EngineError.malformedInput("MT940 text encoding is unsupported") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let tags = try taggedLines(lines)
        let segments = try statementSegments(tags)
        let identity = SourceIdentity(data: data)
        var transactions: [CanonicalTransaction] = []
        var balances: [StatementBalance] = []

        for (segmentIndex, segment) in segments.enumerated() {
            let account = try exactlyOne(segment, tags: ["25"]).value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty else { throw EngineError.malformedInput("MT940 account tag is empty") }
            _ = try exactlyOne(segment, tags: ["20"])
            _ = try exactlyOne(segment, tags: ["28C"])
            let openingTag = try exactlyOne(segment, tags: ["60F", "60M"])
            let closingTag = try exactlyOne(segment, tags: ["62F", "62M"])
            let opening = try parseBalance(openingTag.value)
            let closing = try parseBalance(closingTag.value)
            guard opening.currency == closing.currency else { throw EngineError.malformedInput("MT940 opening/closing currencies differ") }
            guard period.contains(opening.date), period.contains(closing.date) else {
                throw EngineError.periodViolation("MT940 balance dates are outside the selected period")
            }
            balances.append(StatementBalance(
                kind: .opening, account: account, currency: opening.currency, date: opening.date,
                amount: opening.amount, locator: "segment:\(segmentIndex + 1)/line:\(openingTag.line)/opening"
            ))
            balances.append(StatementBalance(
                kind: .closing, account: account, currency: closing.currency, date: closing.date,
                amount: closing.amount, locator: "segment:\(segmentIndex + 1)/line:\(closingTag.line)/closing"
            ))

            let transactionTags = segment.enumerated().filter { $0.element.tag == "61" }
            for (position, tagged) in transactionTags.enumerated() {
                let parsed = try parseTransaction(tagged.element.value)
                guard period.contains(parsed.bookingDate) else {
                    throw EngineError.periodViolation("MT940 transaction on line \(tagged.element.line) is outside the selected period")
                }
                var narrative: String?
                let segmentIndexOfTag = tagged.offset
                if segment.indices.contains(segmentIndexOfTag + 1), segment[segmentIndexOfTag + 1].tag == "86" {
                    narrative = nonempty(segment[segmentIndexOfTag + 1].value.replacingOccurrences(of: "\n", with: " "))
                }
                transactions.append(CanonicalTransaction(
                    sourceID: identity.sourceID,
                    locator: "segment:\(segmentIndex + 1)/line:\(tagged.element.line)/transaction:\(position + 1)",
                    sourceOrdinal: transactions.count,
                    account: account,
                    currency: opening.currency,
                    bookingDate: parsed.bookingDate,
                    valueDate: parsed.valueDate,
                    amount: parsed.amount,
                    strongID: parsed.bankReference,
                    reference: parsed.customerReference,
                    description: narrative,
                    memo: narrative,
                    transactionCode: parsed.transactionCode,
                    originalValues: [
                        "tag61": tagged.element.value,
                        "tag86": narrative ?? ""
                    ]
                ))
                guard transactions.count <= limits.maximumRecords else { throw EngineError.resourceLimit("MT940 transactions") }
            }
        }
        return SourceStatement(
            role: role,
            file: identity.proof(filename: filename, byteCount: data.count),
            replay: replay,
            period: period,
            transactions: transactions,
            balances: balances + replay.balanceOverrides,
            warnings: warnings.sorted()
        )
    }

    private struct TaggedLine {
        let tag: String
        var value: String
        let line: Int
    }

    private struct ParsedBalance {
        let date: LocalDate
        let currency: CurrencyCode
        let amount: ExactAmount
    }

    private struct ParsedTransaction {
        let bookingDate: LocalDate
        let valueDate: LocalDate
        let amount: ExactAmount
        let transactionCode: String?
        let customerReference: String?
        let bankReference: String?
    }

    private func taggedLines(_ lines: [String]) throws -> [TaggedLine] {
        var output: [TaggedLine] = []
        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            guard line.utf8.count <= limits.maximumFieldBytes else { throw EngineError.resourceLimit("MT940 line bytes") }
            if line.isEmpty || line == "-" { continue }
            if line.hasPrefix(":"), let secondColon = line.dropFirst().firstIndex(of: ":") {
                let tag = String(line[line.index(after: line.startIndex)..<secondColon])
                guard !tag.isEmpty, tag.allSatisfy({ $0.isNumber || $0.isLetter }) else {
                    throw EngineError.malformedInput("invalid MT940 tag on line \(lineNumber)")
                }
                output.append(TaggedLine(tag: tag.uppercased(), value: String(line[line.index(after: secondColon)...]), line: lineNumber))
            } else {
                guard !output.isEmpty else { throw EngineError.malformedInput("MT940 continuation precedes a tag") }
                output[output.count - 1].value += "\n" + line
            }
        }
        return output
    }

    private func statementSegments(_ tags: [TaggedLine]) throws -> [[TaggedLine]] {
        var output: [[TaggedLine]] = []
        var current: [TaggedLine] = []
        for tag in tags {
            if tag.tag == "20" {
                if !current.isEmpty {
                    guard current.contains(where: { $0.tag == "62F" || $0.tag == "62M" }) else {
                        throw EngineError.malformedInput("MT940 segment began before the prior segment closed")
                    }
                    output.append(current)
                }
                current = [tag]
                continue
            }
            guard !current.isEmpty else { throw EngineError.malformedInput("MT940 tag appears outside a :20: segment") }
            current.append(tag)
        }
        if !current.isEmpty {
            guard current.contains(where: { $0.tag == "62F" || $0.tag == "62M" }) else {
                throw EngineError.malformedInput("MT940 statement segment is truncated")
            }
            output.append(current)
        }
        guard !output.isEmpty else { throw EngineError.malformedInput("MT940 statement segment is absent") }
        return output
    }

    private func exactlyOne(_ segment: [TaggedLine], tags: Set<String>) throws -> TaggedLine {
        let matches = segment.filter { tags.contains($0.tag) }
        guard matches.count == 1 else { throw EngineError.malformedInput("MT940 requires exactly one of \(tags.sorted().joined(separator: "/"))") }
        return matches[0]
    }

    private func parseBalance(_ raw: String) throws -> ParsedBalance {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 11 else { throw EngineError.malformedInput("MT940 balance is truncated") }
        let sign = value.first
        guard sign == "C" || sign == "D" else { throw EngineError.malformedInput("MT940 balance sign is invalid") }
        let dateStart = value.index(after: value.startIndex)
        let dateEnd = value.index(dateStart, offsetBy: 6)
        let currencyEnd = value.index(dateEnd, offsetBy: 3)
        let date = try compactDate(String(value[dateStart..<dateEnd]))
        let currency = try CurrencyCode(String(value[dateEnd..<currencyEnd]))
        let magnitude = try ExactAmount(parsing: String(value[currencyEnd...]), decimalSeparator: ",")
        let amount = sign == "D" ? try ExactAmount.zero.subtracting(magnitude) : magnitude
        return ParsedBalance(date: date, currency: currency, amount: amount)
    }

    private func parseTransaction(_ raw: String) throws -> ParsedTransaction {
        let value = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        guard value.count >= 10 else { throw EngineError.malformedInput("MT940 :61: record is truncated") }
        var cursor = value.startIndex
        let dateEnd = value.index(cursor, offsetBy: 6)
        let valueDate = try compactDate(String(value[cursor..<dateEnd]))
        cursor = dateEnd
        if value.distance(from: cursor, to: value.endIndex) >= 4 {
            let possibleEntry = value[cursor..<value.index(cursor, offsetBy: 4)]
            if possibleEntry.allSatisfy(\.isNumber) { cursor = value.index(cursor, offsetBy: 4) }
        }
        var reversal = false
        if cursor < value.endIndex, value[cursor] == "R" { reversal = true; cursor = value.index(after: cursor) }
        guard cursor < value.endIndex, value[cursor] == "C" || value[cursor] == "D" else {
            throw EngineError.malformedInput("MT940 debit/credit mark is missing")
        }
        let credit = value[cursor] == "C"
        cursor = value.index(after: cursor)
        if cursor < value.endIndex, value[cursor].isLetter { cursor = value.index(after: cursor) }
        let amountStart = cursor
        while cursor < value.endIndex, value[cursor].isNumber || value[cursor] == "," { cursor = value.index(after: cursor) }
        guard cursor > amountStart else { throw EngineError.malformedInput("MT940 transaction amount is missing") }
        let magnitude = try ExactAmount(parsing: String(value[amountStart..<cursor]), decimalSeparator: ",")
        var amount = credit ? magnitude : try ExactAmount.zero.subtracting(magnitude)
        if reversal { amount = try ExactAmount.zero.subtracting(amount) }
        guard cursor < value.endIndex, value[cursor] == "N" else { throw EngineError.malformedInput("MT940 transaction type marker N is missing") }
        cursor = value.index(after: cursor)
        guard value.distance(from: cursor, to: value.endIndex) >= 3 else { throw EngineError.malformedInput("MT940 transaction code is truncated") }
        let codeEnd = value.index(cursor, offsetBy: 3)
        let code = String(value[cursor..<codeEnd])
        let references = String(value[codeEnd...])
        let parts = references.components(separatedBy: "//")
        let customer = nonempty(parts.first)
        let bank = parts.count > 1 ? nonempty(parts[1]) : nil
        return ParsedTransaction(
            bookingDate: valueDate,
            valueDate: valueDate,
            amount: amount,
            transactionCode: nonempty(code),
            customerReference: customer,
            bankReference: bank
        )
    }

    private func compactDate(_ raw: String) throws -> LocalDate {
        guard raw.count == 6, raw.allSatisfy(\.isNumber),
              let year = Int(raw.prefix(2)), let month = Int(raw.dropFirst(2).prefix(2)), let day = Int(raw.suffix(2)) else {
            throw EngineError.invalidDate(raw)
        }
        return try LocalDate(year: year >= 70 ? 1_900 + year : 2_000 + year, month: month, day: day)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
