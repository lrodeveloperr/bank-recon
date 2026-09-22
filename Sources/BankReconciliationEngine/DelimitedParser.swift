import Foundation

public struct ParserLimits: Hashable, Codable, Sendable {
    public let maximumBytes: Int
    public let maximumRecords: Int
    public let maximumColumns: Int
    public let maximumFieldBytes: Int
    public let maximumUnicodeScalars: Int

    public init(
        maximumBytes: Int = 64 * 1_024 * 1_024,
        maximumRecords: Int = 500_000,
        maximumColumns: Int = 256,
        maximumFieldBytes: Int = 16_384,
        maximumUnicodeScalars: Int = 10_000_000
    ) {
        self.maximumBytes = maximumBytes
        self.maximumRecords = maximumRecords
        self.maximumColumns = maximumColumns
        self.maximumFieldBytes = maximumFieldBytes
        self.maximumUnicodeScalars = maximumUnicodeScalars
    }
}

public struct DelimitedParser: Sendable {
    public static let version = "delimited-2.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        mapping: DelimitedMapping,
        format: InputFormat
    ) throws -> SourceStatement {
        guard format == .csv || format == .tsv else { throw EngineError.unsupportedFormat(format) }
        guard limits.maximumBytes > 0, limits.maximumRecords > 0, limits.maximumColumns > 0,
              limits.maximumFieldBytes > 0, limits.maximumUnicodeScalars > 0 else {
            throw EngineError.invalidConfiguration("parser limits must be positive")
        }
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("input bytes") }
        guard mapping.delimiter.unicodeScalars.count == 1,
              mapping.decimalSeparator.unicodeScalars.count == 1,
              mapping.delimiter != "\"", mapping.delimiter != "\r", mapping.delimiter != "\n" else {
            throw EngineError.invalidConfiguration("separators must be one scalar")
        }
        let delimiterBytes = Array(String(mapping.delimiter).utf8)
        guard delimiterBytes.count == 1, let delimiter = delimiterBytes.first else {
            throw EngineError.invalidConfiguration("delimiter must be one ASCII byte")
        }
        guard mapping.dateColumn != mapping.amountColumn else {
            throw EngineError.invalidConfiguration("date and amount columns must differ")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngineError.malformedInput("CSV/TSV must be UTF-8 in this checkpoint")
        }
        guard text.unicodeScalars.count <= limits.maximumUnicodeScalars else {
            throw EngineError.resourceLimit("unicode scalars")
        }
        let rows = try tokenize(data, delimiter: delimiter)
        guard !rows.isEmpty else { throw EngineError.malformedInput("empty delimited source") }

        let candidateRows = mapping.hasHeader ? Array(rows.dropFirst()) : rows
        let dataRows = candidateRows.filter { !$0.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
        let expectedWidth = rows[0].fields.count
        guard expectedWidth > 0, expectedWidth <= limits.maximumColumns else {
            throw EngineError.resourceLimit("column count")
        }
        guard dataRows.allSatisfy({ $0.fields.count == expectedWidth }) else {
            throw EngineError.malformedInput("inconsistent row width")
        }

        let requiredIndices = [mapping.dateColumn, mapping.amountColumn] + [
            mapping.accountColumn, mapping.currencyColumn, mapping.strongIDColumn,
            mapping.referenceColumn, mapping.descriptionColumn, mapping.runningBalanceColumn
        ].compactMap { $0 }
        guard requiredIndices.allSatisfy({ $0 >= 0 && $0 < expectedWidth }) else {
            throw EngineError.invalidConfiguration("mapping references a missing column")
        }

        let digest = Hashing.sha256(data)
        let sourceID = "source-" + digest
        var transactions: [CanonicalTransaction] = []
        transactions.reserveCapacity(dataRows.count)

        for (ordinal, row) in dataRows.enumerated() {
            guard !row.fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let values = row.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let date = try parseDate(values[mapping.dateColumn], order: mapping.dateOrder)
            guard period.contains(date) else {
                throw EngineError.periodViolation("row \(row.line): \(date) is outside \(period.start)...\(period.end)")
            }
            let amount = try ExactAmount(
                parsing: values[mapping.amountColumn],
                decimalSeparator: mapping.decimalSeparator,
                groupingSeparator: mapping.groupingSeparator
            )
            let (account, accountDerived) = try mappedOrDefault(values, index: mapping.accountColumn, fallback: mapping.defaultAccount, label: "account")
            let (currencyRaw, currencyDerived) = try mappedOrDefault(values, index: mapping.currencyColumn, fallback: mapping.defaultCurrency, label: "currency")
            let currency = try CurrencyCode(currencyRaw)
            let original = Dictionary(uniqueKeysWithValues: row.fields.enumerated().map { ("column:\($0.offset)", $0.element) })
            let runningBalance: ExactAmount?
            if let index = mapping.runningBalanceColumn, !values[index].isEmpty {
                runningBalance = try ExactAmount(
                    parsing: values[index],
                    decimalSeparator: mapping.decimalSeparator,
                    groupingSeparator: mapping.groupingSeparator
                )
            } else {
                runningBalance = nil
            }
            var derived: Set<String> = []
            if accountDerived { derived.insert("account") }
            if currencyDerived { derived.insert("currency") }
            transactions.append(CanonicalTransaction(
                sourceID: sourceID,
                locator: "line:\(row.line)",
                sourceOrdinal: ordinal,
                account: account,
                currency: currency,
                bookingDate: date,
                amount: amount,
                runningBalance: runningBalance,
                strongID: optional(values, mapping.strongIDColumn),
                reference: optional(values, mapping.referenceColumn),
                description: optional(values, mapping.descriptionColumn),
                originalValues: original,
                derivedFields: derived
            ))
        }

        return SourceStatement(
            role: role,
            file: SourceFileProof(sourceID: sourceID, filename: filename, byteCount: data.count, sha256: digest),
            replay: ParseReplayDescriptor(format: format, parserVersion: Self.version, delimitedMapping: mapping),
            period: period,
            transactions: transactions
        )
    }

    private struct Row {
        let line: Int
        let fields: [String]
    }

    private func tokenize(_ data: Data, delimiter: UInt8) throws -> [Row] {
        let bytes = Array(data)
        var rows: [Row] = []
        var fields: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var justClosedQuote = false
        var line = 1
        var recordStartLine = 1
        var index = 0

        func appendField() throws {
            guard let decoded = String(bytes: field, encoding: .utf8) else {
                throw EngineError.malformedInput("field contains invalid UTF-8")
            }
            fields.append(decoded)
            guard fields.count <= limits.maximumColumns else { throw EngineError.resourceLimit("columns") }
            field.removeAll(keepingCapacity: true)
            justClosedQuote = false
        }

        func appendByte(_ byte: UInt8) throws {
            guard field.count < limits.maximumFieldBytes else { throw EngineError.resourceLimit("field bytes") }
            field.append(byte)
        }

        func appendRow() throws {
            try appendField()
            rows.append(Row(line: recordStartLine, fields: fields))
            guard rows.count <= limits.maximumRecords else { throw EngineError.resourceLimit("records") }
            fields = []
            recordStartLine = line + 1
        }

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1
            if inQuotes {
                if byte == 34 {
                    if next < bytes.count, bytes[next] == 34 {
                        try appendByte(34)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    justClosedQuote = true
                } else if byte == 13 {
                    try appendByte(13)
                    if next < bytes.count, bytes[next] == 10 {
                        try appendByte(10)
                        index += 2
                    } else {
                        index += 1
                    }
                    line += 1
                    continue
                } else {
                    try appendByte(byte)
                    if byte == 10 { line += 1 }
                }
            } else if justClosedQuote {
                if byte == delimiter {
                    try appendField()
                } else if byte == 10 {
                    try appendRow()
                    line += 1
                } else if byte == 13 {
                    if next < bytes.count, bytes[next] == 10 { index += 1 }
                    try appendRow()
                    line += 1
                } else {
                    throw EngineError.malformedInput("characters after closing quote at line \(line)")
                }
            } else if byte == 34 {
                guard field.isEmpty else { throw EngineError.malformedInput("quote inside unquoted field at line \(line)") }
                inQuotes = true
            } else if byte == delimiter {
                try appendField()
            } else if byte == 10 {
                try appendRow()
                line += 1
            } else if byte == 13 {
                if next < bytes.count, bytes[next] == 10 { index += 1 }
                try appendRow()
                line += 1
            } else {
                try appendByte(byte)
            }
            index += 1
        }
        guard !inQuotes else { throw EngineError.malformedInput("unterminated quoted field") }
        if !field.isEmpty || !fields.isEmpty || justClosedQuote { try appendRow() }
        return rows
    }

    private func parseDate(_ raw: String, order: DateOrder) throws -> LocalDate {
        guard raw.utf8.count == 10 else { throw EngineError.invalidDate(raw) }
        let separator = raw.contains("-") ? Character("-") : Character("/")
        let fields = raw.split(separator: separator, omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { throw EngineError.invalidDate(raw) }
        switch order {
        case .ymd:
            guard fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
                  let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]) else { throw EngineError.invalidDate(raw) }
            return try LocalDate(year: year, month: month, day: day)
        case .dmy:
            guard fields[0].count == 2, fields[1].count == 2, fields[2].count == 4,
                  let year = Int(fields[2]), let month = Int(fields[1]), let day = Int(fields[0]) else { throw EngineError.invalidDate(raw) }
            return try LocalDate(year: year, month: month, day: day)
        case .mdy:
            guard fields[0].count == 2, fields[1].count == 2, fields[2].count == 4,
                  let year = Int(fields[2]), let month = Int(fields[0]), let day = Int(fields[1]) else { throw EngineError.invalidDate(raw) }
            return try LocalDate(year: year, month: month, day: day)
        }
    }

    private func optional(_ values: [String], _ index: Int?) -> String? {
        guard let index, !values[index].isEmpty else { return nil }
        return values[index]
    }

    private func mappedOrDefault(_ values: [String], index: Int?, fallback: String?, label: String) throws -> (String, Bool) {
        if let index, !values[index].isEmpty { return (values[index], false) }
        guard let fallback, !fallback.isEmpty else { throw EngineError.malformedInput("missing \(label)") }
        return (fallback, true)
    }
}

public struct FormatRouter: Sendable {
    private let delimited: DelimitedParser
    public init(limits: ParserLimits = ParserLimits()) { self.delimited = DelimitedParser(limits: limits) }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        switch replay.format {
        case .csv, .tsv:
            guard replay.parserVersion == DelimitedParser.version else {
                throw EngineError.invalidConfiguration("unsupported delimited parser version: \(replay.parserVersion)")
            }
            guard let mapping = replay.delimitedMapping else { throw EngineError.invalidConfiguration("missing delimited mapping") }
            let parsed = try delimited.parse(data: data, filename: filename, role: role, period: period, mapping: mapping, format: replay.format)
            return SourceStatement(
                role: parsed.role,
                file: parsed.file,
                replay: replay,
                period: parsed.period,
                transactions: parsed.transactions,
                balances: replay.balanceOverrides,
                completeness: parsed.completeness,
                warnings: parsed.warnings,
                invalidLocators: parsed.invalidLocators
            )
        default:
            throw EngineError.unsupportedFormat(replay.format)
        }
    }
}
