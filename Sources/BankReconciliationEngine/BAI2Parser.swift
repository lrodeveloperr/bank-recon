import Foundation

public struct BAI2Parser: Sendable {
    public static let version = "bai2-1.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        guard replay.format == .bai2 else { throw EngineError.unsupportedFormat(replay.format) }
        guard replay.parserVersion == Self.version else {
            throw EngineError.invalidConfiguration("unsupported BAI2 parser version: \(replay.parserVersion)")
        }
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("BAI2 bytes") }
        guard let text = String(data: data, encoding: .ascii) else { throw EngineError.malformedInput("BAI2 must be ASCII") }
        let parsedRecords = try records(text)
        guard parsedRecords.first?.fields.first == "01", parsedRecords.last?.fields.first == "99" else {
            throw EngineError.malformedInput("BAI2 requires 01 and 99 file envelopes")
        }
        guard parsedRecords.filter({ $0.fields.first == "01" }).count == 1,
              parsedRecords.filter({ $0.fields.first == "99" }).count == 1 else {
            throw EngineError.malformedInput("BAI2 file envelopes are duplicated")
        }
        guard parsedRecords[0].fields.count >= 9, parsedRecords[0].fields[8] == "2" else {
            throw EngineError.malformedInput("unsupported BAI version")
        }
        let identity = SourceIdentity(data: data)
        var transactions: [CanonicalTransaction] = []
        var balances: [StatementBalance] = []
        var warnings: [String] = []
        var groupIndex = 0
        var cursor = 1
        var fileControl = ExactAmount.zero
        var fileGroupCount = 0

        while cursor < parsedRecords.count - 1 {
            let groupHeader = parsedRecords[cursor]
            guard groupHeader.fields.first == "02", groupHeader.fields.count >= 8 else {
                throw EngineError.malformedInput("BAI2 expected a 02 group header")
            }
            groupIndex += 1
            fileGroupCount += 1
            let groupStartPhysical = groupHeader.firstPhysicalIndex
            let groupDate = try compactDate(groupHeader.fields[4])
            guard period.contains(groupDate) else { throw EngineError.periodViolation("BAI2 group \(groupIndex) is outside the selected period") }
            let groupCurrencyRaw = nonempty(groupHeader.fields[6]) ?? replay.structuredProfile?.defaultCurrency
            guard let groupCurrencyRaw else { throw EngineError.malformedInput("BAI2 group currency is missing") }
            let groupCurrency = try CurrencyCode(groupCurrencyRaw)
            cursor += 1
            var groupControl = ExactAmount.zero
            var accountCount = 0

            while cursor < parsedRecords.count, parsedRecords[cursor].fields.first == "03" {
                let accountHeader = parsedRecords[cursor]
                guard accountHeader.fields.count >= 4 else { throw EngineError.malformedInput("BAI2 03 account record is incomplete") }
                accountCount += 1
                let accountStartPhysical = accountHeader.firstPhysicalIndex
                let account = accountHeader.fields[1]
                guard !account.isEmpty else { throw EngineError.malformedInput("BAI2 account identifier is missing") }
                let accountCurrency = try CurrencyCode(nonempty(accountHeader.fields[2]) ?? groupCurrency.value)
                guard accountCurrency == groupCurrency else { throw EngineError.malformedInput("BAI2 account currency differs from group currency") }
                let summaries = try summaryAmounts(accountHeader.fields, currency: accountCurrency)
                var accountControl = try summaries.reduce(.zero) { try $0.adding($1.amount) }
                for summary in summaries where summary.code == "010" || summary.code == "015" {
                    balances.append(StatementBalance(
                        kind: summary.code == "010" ? .opening : .closing,
                        account: account,
                        currency: accountCurrency,
                        date: groupDate,
                        amount: summary.amount,
                        locator: "group:\(groupIndex)/account:\(accountCount)/summary:\(summary.code)"
                    ))
                }
                cursor += 1
                var detailIndex = 0
                while cursor < parsedRecords.count, parsedRecords[cursor].fields.first == "16" {
                    let detail = parsedRecords[cursor]
                    guard detail.fields.count >= 4, let code = Int(detail.fields[1]) else {
                        throw EngineError.malformedInput("BAI2 16 transaction record is incomplete")
                    }
                    detailIndex += 1
                    let literal = try impliedAmount(detail.fields[2], currency: accountCurrency)
                    accountControl = try accountControl.adding(literal)
                    if (100...699).contains(code) {
                        let amount = code >= 400 ? try ExactAmount.zero.subtracting(literal) : literal
                        let bankReference = detail.fields.count > 4 ? nonempty(detail.fields[4]) : nil
                        let customerReference = detail.fields.count > 5 ? nonempty(detail.fields[5]) : nil
                        let description = detail.fields.count > 6 ? nonempty(detail.fields.dropFirst(6).joined(separator: ",")) : nil
                        transactions.append(CanonicalTransaction(
                            sourceID: identity.sourceID,
                            locator: "group:\(groupIndex)/account:\(accountCount)/transaction:\(detailIndex)/record:\(detail.firstPhysicalIndex)",
                            sourceOrdinal: transactions.count,
                            account: account,
                            currency: accountCurrency,
                            bookingDate: groupDate,
                            amount: amount,
                            strongID: bankReference,
                            reference: customerReference ?? bankReference,
                            description: description,
                            memo: description,
                            transactionCode: detail.fields[1],
                            originalValues: Dictionary(uniqueKeysWithValues: detail.fields.enumerated().map { ("field:\($0.offset)", $0.element) }),
                            derivedFields: ["bookingDate"]
                        ))
                        guard transactions.count <= limits.maximumRecords else { throw EngineError.resourceLimit("BAI2 transactions") }
                    } else {
                        warnings.append("Skipped non-monetary BAI2 type code \(code) in account \(account)")
                    }
                    cursor += 1
                }
                guard cursor < parsedRecords.count, parsedRecords[cursor].fields.first == "49" else {
                    throw EngineError.malformedInput("BAI2 account is missing its 49 trailer")
                }
                let accountTrailer = parsedRecords[cursor]
                guard accountTrailer.fields.count == 3 else { throw EngineError.malformedInput("BAI2 49 trailer field count is invalid") }
                let claimedControl = try impliedAmount(accountTrailer.fields[1], currency: accountCurrency)
                let claimedRecords = try positiveInteger(accountTrailer.fields[2], label: "BAI2 account record count")
                let actualRecords = accountTrailer.lastPhysicalIndex - accountStartPhysical + 1
                guard claimedRecords == actualRecords else { throw EngineError.integrityFailure("BAI2 account record count mismatch") }
                guard claimedControl == accountControl else { throw EngineError.integrityFailure("BAI2 account control total mismatch") }
                groupControl = try groupControl.adding(claimedControl)
                cursor += 1
            }

            guard cursor < parsedRecords.count, parsedRecords[cursor].fields.first == "98" else {
                throw EngineError.malformedInput("BAI2 group is missing its 98 trailer")
            }
            let groupTrailer = parsedRecords[cursor]
            guard groupTrailer.fields.count == 4 else { throw EngineError.malformedInput("BAI2 98 trailer field count is invalid") }
            let claimedGroupControl = try impliedAmount(groupTrailer.fields[1], currency: groupCurrency)
            let claimedAccounts = try positiveInteger(groupTrailer.fields[2], label: "BAI2 account count")
            let claimedGroupRecords = try positiveInteger(groupTrailer.fields[3], label: "BAI2 group record count")
            let actualGroupRecords = groupTrailer.lastPhysicalIndex - groupStartPhysical + 1
            guard claimedGroupControl == groupControl else { throw EngineError.integrityFailure("BAI2 group control total mismatch") }
            guard claimedAccounts == accountCount else { throw EngineError.integrityFailure("BAI2 group account count mismatch") }
            guard claimedGroupRecords == actualGroupRecords else { throw EngineError.integrityFailure("BAI2 group record count mismatch") }
            fileControl = try fileControl.adding(claimedGroupControl)
            cursor += 1
        }

        let fileTrailer = parsedRecords[parsedRecords.count - 1]
        guard fileTrailer.fields.count == 4 else { throw EngineError.malformedInput("BAI2 99 trailer field count is invalid") }
        let trailerCurrency = try CurrencyCode(replay.structuredProfile?.defaultCurrency ?? parsedRecords.dropFirst().first(where: { $0.fields.first == "02" })?.fields[6] ?? "")
        let claimedFileControl = try impliedAmount(fileTrailer.fields[1], currency: trailerCurrency)
        let claimedGroups = try positiveInteger(fileTrailer.fields[2], label: "BAI2 file group count")
        let claimedFileRecords = try positiveInteger(fileTrailer.fields[3], label: "BAI2 file record count")
        guard claimedFileControl == fileControl else { throw EngineError.integrityFailure("BAI2 file control total mismatch") }
        guard claimedGroups == fileGroupCount else { throw EngineError.integrityFailure("BAI2 file group count mismatch") }
        guard claimedFileRecords == fileTrailer.lastPhysicalIndex else { throw EngineError.integrityFailure("BAI2 file record count mismatch") }

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

    private struct LogicalRecord {
        var fields: [String]
        let firstPhysicalIndex: Int
        var lastPhysicalIndex: Int
    }

    private struct SummaryAmount {
        let code: String
        let amount: ExactAmount
    }

    private func records(_ text: String) throws -> [LogicalRecord] {
        var output: [LogicalRecord] = []
        var physicalIndex = 0
        var current = ""
        for character in text {
            if character == "/" {
                physicalIndex += 1
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw EngineError.malformedInput("empty BAI2 physical record") }
                let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard fields.count <= limits.maximumColumns else { throw EngineError.resourceLimit("BAI2 fields") }
                if fields.first == "88" {
                    guard !output.isEmpty, !["01", "02", "49", "98", "99"].contains(output[output.count - 1].fields.first ?? "") else {
                        throw EngineError.malformedInput("BAI2 88 continuation has no continuable record")
                    }
                    output[output.count - 1].fields.append(contentsOf: fields.dropFirst())
                    output[output.count - 1].lastPhysicalIndex = physicalIndex
                } else {
                    output.append(LogicalRecord(fields: fields, firstPhysicalIndex: physicalIndex, lastPhysicalIndex: physicalIndex))
                }
                guard physicalIndex <= limits.maximumRecords else { throw EngineError.resourceLimit("BAI2 physical records") }
                current = ""
            } else {
                current.append(character)
                guard current.utf8.count <= limits.maximumFieldBytes * limits.maximumColumns else {
                    throw EngineError.resourceLimit("BAI2 physical record bytes")
                }
            }
        }
        guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.malformedInput("BAI2 final physical record is missing / termination")
        }
        return output
    }

    private func summaryAmounts(_ fields: [String], currency: CurrencyCode) throws -> [SummaryAmount] {
        var output: [SummaryAmount] = []
        var index = 3
        while index < fields.count {
            guard index + 3 < fields.count, fields[index].count == 3, fields[index].allSatisfy(\.isNumber) else {
                throw EngineError.malformedInput("BAI2 summary group is truncated")
            }
            let code = fields[index]
            let amount = try impliedAmount(fields[index + 1], currency: currency)
            _ = try nonnegativeInteger(fields[index + 2], label: "BAI2 summary item count")
            let fundsType = fields[index + 3]
            output.append(SummaryAmount(code: code, amount: amount))
            index += 4
            if fundsType == "D" {
                guard index < fields.count else { throw EngineError.malformedInput("BAI2 distributed availability is truncated") }
                let distributions = try nonnegativeInteger(fields[index], label: "BAI2 availability distribution count")
                index += 1 + (distributions * 2)
                guard index <= fields.count else { throw EngineError.malformedInput("BAI2 availability distribution is truncated") }
            }
        }
        return output
    }

    private func impliedAmount(_ raw: String, currency: CurrencyCode) throws -> ExactAmount {
        guard !raw.isEmpty, raw.utf8.count <= ExactAmount.maximumInputBytes,
              raw.drop(while: { $0 == "+" || $0 == "-" }).allSatisfy(\.isNumber),
              let value = Int64(raw) else { throw EngineError.invalidAmount(raw) }
        return try ExactAmount(mantissa: value, scale: UInt8(minorUnits(currency)))
    }

    private func minorUnits(_ currency: CurrencyCode) -> Int {
        let zero: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]
        let three: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
        if zero.contains(currency.value) { return 0 }
        if three.contains(currency.value) { return 3 }
        return 2
    }

    private func compactDate(_ raw: String) throws -> LocalDate {
        guard raw.count == 6, raw.allSatisfy(\.isNumber),
              let year = Int(raw.prefix(2)), let month = Int(raw.dropFirst(2).prefix(2)), let day = Int(raw.suffix(2)) else {
            throw EngineError.invalidDate(raw)
        }
        return try LocalDate(year: year >= 70 ? 1_900 + year : 2_000 + year, month: month, day: day)
    }

    private func positiveInteger(_ raw: String, label: String) throws -> Int {
        let value = try nonnegativeInteger(raw, label: label)
        guard value > 0 else { throw EngineError.malformedInput("\(label) must be positive") }
        return value
    }

    private func nonnegativeInteger(_ raw: String, label: String) throws -> Int {
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber), let value = Int(raw), value >= 0 else {
            throw EngineError.malformedInput("\(label) is invalid")
        }
        return value
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
