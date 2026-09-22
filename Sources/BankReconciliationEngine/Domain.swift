import Foundation

public enum EngineError: Error, Equatable, Sendable {
    case invalidAmount(String)
    case arithmeticOverflow
    case invalidDate(String)
    case invalidCurrency(String)
    case invalidConfiguration(String)
    case malformedInput(String)
    case resourceLimit(String)
    case unsupportedFormat(InputFormat)
    case roleMismatch(String)
    case periodViolation(String)
    case staleRevision
    case lockedMutation
    case integrityFailure(String)
    case notFound(String)
    case entitlementRequired(EntitlementTier)
    case purchaseVerificationFailed
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAmount(let value): "Invalid exact amount: \(value)"
        case .arithmeticOverflow: "Exact arithmetic exceeded the supported range."
        case .invalidDate(let value): "Invalid exact date: \(value)"
        case .invalidCurrency(let value): "Invalid ISO currency: \(value)"
        case .invalidConfiguration(let value): "Invalid configuration: \(value)"
        case .malformedInput(let value): "Malformed input: \(value)"
        case .resourceLimit(let value): "Resource limit exceeded: \(value)"
        case .unsupportedFormat(let value): "Unsupported adapter in this checkpoint: \(value.rawValue)"
        case .roleMismatch(let value): "Source roles do not match the selected mode: \(value)"
        case .periodViolation(let value): "Source period violation: \(value)"
        case .staleRevision: "The stored revision changed. Reload before saving."
        case .lockedMutation: "A locked reconciliation is immutable."
        case .integrityFailure(let value): "Integrity check failed: \(value)"
        case .notFound(let value): "Not found: \(value)"
        case .entitlementRequired(let tier): "This action requires the \(tier.rawValue) purchase."
        case .purchaseVerificationFailed: "The App Store purchase could not be verified."
        }
    }
}

public struct ExactAmount: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public static let maximumScale = 6
    public static let maximumInputBytes = 64

    public let mantissa: Int64
    public let scale: UInt8

    private init(normalizedMantissa: Int64, normalizedScale: UInt8) {
        self.mantissa = normalizedMantissa
        self.scale = normalizedScale
    }

    public init(mantissa: Int64, scale: UInt8) throws {
        guard Int(scale) <= Self.maximumScale else { throw EngineError.invalidAmount("scale \(scale)") }
        var value = mantissa
        var places = scale
        while places > 0 && value % 10 == 0 {
            value /= 10
            places -= 1
        }
        self.mantissa = value
        self.scale = places
    }

    public init(
        parsing raw: String,
        decimalSeparator: Character = ".",
        groupingSeparator: Character? = nil
    ) throws {
        guard !raw.isEmpty, raw.utf8.count <= Self.maximumInputBytes else {
            throw EngineError.invalidAmount(raw)
        }
        guard decimalSeparator != groupingSeparator else { throw EngineError.invalidConfiguration("decimal and grouping separators collide") }

        var body = raw
        var negative = false
        if body.first == "+" { body.removeFirst() }
        else if body.first == "-" { negative = true; body.removeFirst() }
        guard !body.isEmpty else { throw EngineError.invalidAmount(raw) }

        let decimalParts = body.split(separator: decimalSeparator, omittingEmptySubsequences: false)
        guard decimalParts.count <= 2 else { throw EngineError.invalidAmount(raw) }
        var integerPart = String(decimalParts[0])
        let fractionPart = decimalParts.count == 2 ? String(decimalParts[1]) : ""
        guard fractionPart.count <= Self.maximumScale else { throw EngineError.invalidAmount(raw) }

        if let groupingSeparator, integerPart.contains(groupingSeparator) {
            let groups = integerPart.split(separator: groupingSeparator, omittingEmptySubsequences: false)
            guard !groups.isEmpty,
                  (1...3).contains(groups[0].count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) else {
                throw EngineError.invalidAmount(raw)
            }
            integerPart = groups.joined()
        }

        let digits = integerPart + fractionPart
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), digits.count <= 19 else {
            throw EngineError.invalidAmount(raw)
        }
        guard let magnitude = UInt64(digits) else { throw EngineError.invalidAmount(raw) }
        let signed: Int64
        if negative {
            let minimumMagnitude = UInt64(Int64.max) + 1
            if magnitude == minimumMagnitude {
                signed = Int64.min
            } else {
                guard magnitude <= UInt64(Int64.max) else { throw EngineError.invalidAmount(raw) }
                signed = -Int64(magnitude)
            }
        } else {
            guard magnitude <= UInt64(Int64.max) else { throw EngineError.invalidAmount(raw) }
            signed = Int64(magnitude)
        }
        try self.init(mantissa: signed, scale: UInt8(fractionPart.count))
    }

    private enum CodingKeys: String, CodingKey { case mantissa, scale }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mantissa = try container.decode(Int64.self, forKey: .mantissa)
        let scale = try container.decode(UInt8.self, forKey: .scale)
        try self.init(mantissa: mantissa, scale: scale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mantissa, forKey: .mantissa)
        try container.encode(scale, forKey: .scale)
    }

    public static let zero = ExactAmount(normalizedMantissa: 0, normalizedScale: 0)

    public func adding(_ other: Self) throws -> Self {
        let target = max(scale, other.scale)
        let left = try rescaledMantissa(to: target)
        let right = try other.rescaledMantissa(to: target)
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw EngineError.arithmeticOverflow }
        return try Self(mantissa: sum, scale: target)
    }

    public func subtracting(_ other: Self) throws -> Self {
        let target = max(scale, other.scale)
        let left = try rescaledMantissa(to: target)
        let right = try other.rescaledMantissa(to: target)
        let (difference, overflow) = left.subtractingReportingOverflow(right)
        guard !overflow else { throw EngineError.arithmeticOverflow }
        return try Self(mantissa: difference, scale: target)
    }

    private func rescaledMantissa(to target: UInt8) throws -> Int64 {
        guard target >= scale, Int(target) <= Self.maximumScale else { throw EngineError.arithmeticOverflow }
        var output = mantissa
        for _ in scale..<target {
            let (next, overflow) = output.multipliedReportingOverflow(by: 10)
            guard !overflow else { throw EngineError.arithmeticOverflow }
            output = next
        }
        return output
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.mantissa < 0, rhs.mantissa >= 0 { return true }
        if lhs.mantissa >= 0, rhs.mantissa < 0 { return false }
        let comparison = compareMagnitude(lhs, rhs)
        return lhs.mantissa < 0 ? comparison > 0 : comparison < 0
    }

    private static func compareMagnitude(_ lhs: Self, _ rhs: Self) -> Int {
        func components(_ value: Self) -> (String, String) {
            let digits = String(value.mantissa.magnitude)
            let places = Int(value.scale)
            let padded = String(repeating: "0", count: max(0, places + 1 - digits.count)) + digits
            let split = padded.index(padded.endIndex, offsetBy: -places)
            let integer = places == 0 ? padded : String(padded[..<split])
            let fraction = places == 0 ? "" : String(padded[split...])
            let trimmed = String(integer.drop(while: { $0 == "0" }))
            return (trimmed.isEmpty ? "0" : trimmed, fraction + String(repeating: "0", count: Self.maximumScale - fraction.count))
        }
        let left = components(lhs)
        let right = components(rhs)
        if left.0.count != right.0.count { return left.0.count < right.0.count ? -1 : 1 }
        if left.0 != right.0 { return left.0 < right.0 ? -1 : 1 }
        if left.1 == right.1 { return 0 }
        return left.1 < right.1 ? -1 : 1
    }

    public var description: String {
        let negative = mantissa < 0
        let digits = String(mantissa.magnitude)
        guard scale > 0 else { return (negative ? "-" : "") + digits }
        let places = Int(scale)
        let padded = String(repeating: "0", count: max(0, places + 1 - digits.count)) + digits
        let split = padded.index(padded.endIndex, offsetBy: -places)
        return (negative ? "-" : "") + String(padded[..<split]) + "." + String(padded[split...])
    }
}

public struct LocalDate: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw EngineError.invalidDate("\(year)-\(month)-\(day)")
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw EngineError.invalidConfiguration("UTC unavailable") }
        calendar.timeZone = utc
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw EngineError.invalidDate("\(year)-\(month)-\(day)")
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(iso8601 raw: String) throws {
        let bytes = Array(raw.utf8)
        guard bytes.count == 10,
              bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ pair in
                  let (index, byte) = pair
                  return index == 4 || index == 7 || (48...57).contains(byte)
              }) else {
            throw EngineError.invalidDate(raw)
        }
        guard let year = Int(String(decoding: bytes[0..<4], as: UTF8.self)),
              let month = Int(String(decoding: bytes[5..<7], as: UTF8.self)),
              let day = Int(String(decoding: bytes[8..<10], as: UTF8.self)) else {
            throw EngineError.invalidDate(raw)
        }
        try self.init(year: year, month: month, day: day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(iso8601: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

public struct ReconciliationPeriod: Hashable, Codable, Sendable {
    public let start: LocalDate
    public let end: LocalDate

    public init(start: LocalDate, end: LocalDate) throws {
        guard start <= end else { throw EngineError.invalidConfiguration("period start is after end") }
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: container.decode(LocalDate.self, forKey: .start), end: container.decode(LocalDate.self, forKey: .end))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }

    public func contains(_ date: LocalDate) -> Bool { start <= date && date <= end }
}

public struct CurrencyCode: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let value: String

    public init(_ raw: String) throws {
        let normalized = raw.uppercased()
        guard normalized.utf8.count == 3,
              normalized.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw EngineError.invalidCurrency(raw)
        }
        self.value = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public var description: String { value }
}

public enum ReconciliationMode: String, Codable, Sendable, Hashable { case bankVsLedger, exportVsExport, singleStatement }
public enum SourceRole: String, Codable, Sendable, Hashable { case bank, ledger, olderExport, newerExport, statement }
public enum SourceCompleteness: String, Codable, Sendable, Hashable { case complete, incomplete, notificationOnly }
public enum InputFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case csv, tsv, xlsx, ofx, qfx, qbo, qif, qmtf, camt053, camt054, mt940, bai2
}
public enum DateOrder: String, Codable, Sendable, Hashable { case ymd, dmy, mdy }

public struct MatchingPolicy: Hashable, Codable, Sendable {
    public let fuzzyMatchingEnabled: Bool
    public let maximumDateDistanceDays: Int
    public let minimumTextSimilarityPermille: Int
    public let maximumFuzzyCandidatePairs: Int
    public let maximumComparedTextScalars: Int
    public let splitMergeCandidatesEnabled: Bool
    public let maximumSplitMergeGroupSize: Int
    public let maximumSplitMergeEvaluations: Int

    public init(
        fuzzyMatchingEnabled: Bool = true,
        maximumDateDistanceDays: Int = 3,
        minimumTextSimilarityPermille: Int = 850,
        maximumFuzzyCandidatePairs: Int = 20_000,
        maximumComparedTextScalars: Int = 256,
        splitMergeCandidatesEnabled: Bool = true,
        maximumSplitMergeGroupSize: Int = 4,
        maximumSplitMergeEvaluations: Int = 50_000
    ) {
        self.fuzzyMatchingEnabled = fuzzyMatchingEnabled
        self.maximumDateDistanceDays = maximumDateDistanceDays
        self.minimumTextSimilarityPermille = minimumTextSimilarityPermille
        self.maximumFuzzyCandidatePairs = maximumFuzzyCandidatePairs
        self.maximumComparedTextScalars = maximumComparedTextScalars
        self.splitMergeCandidatesEnabled = splitMergeCandidatesEnabled
        self.maximumSplitMergeGroupSize = maximumSplitMergeGroupSize
        self.maximumSplitMergeEvaluations = maximumSplitMergeEvaluations
    }

    public static let `default` = MatchingPolicy()
}

public struct DelimitedMapping: Hashable, Codable, Sendable {
    public let delimiter: Character
    public let hasHeader: Bool
    public let dateColumn: Int
    public let amountColumn: Int
    public let accountColumn: Int?
    public let currencyColumn: Int?
    public let strongIDColumn: Int?
    public let referenceColumn: Int?
    public let descriptionColumn: Int?
    public let runningBalanceColumn: Int?
    public let dateOrder: DateOrder
    public let decimalSeparator: Character
    public let groupingSeparator: Character?
    public let defaultAccount: String?
    public let defaultCurrency: String?

    public init(
        delimiter: Character,
        hasHeader: Bool,
        dateColumn: Int,
        amountColumn: Int,
        accountColumn: Int? = nil,
        currencyColumn: Int? = nil,
        strongIDColumn: Int? = nil,
        referenceColumn: Int? = nil,
        descriptionColumn: Int? = nil,
        runningBalanceColumn: Int? = nil,
        dateOrder: DateOrder,
        decimalSeparator: Character,
        groupingSeparator: Character? = nil,
        defaultAccount: String? = nil,
        defaultCurrency: String? = nil
    ) {
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.dateColumn = dateColumn
        self.amountColumn = amountColumn
        self.accountColumn = accountColumn
        self.currencyColumn = currencyColumn
        self.strongIDColumn = strongIDColumn
        self.referenceColumn = referenceColumn
        self.descriptionColumn = descriptionColumn
        self.runningBalanceColumn = runningBalanceColumn
        self.dateOrder = dateOrder
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.defaultAccount = defaultAccount
        self.defaultCurrency = defaultCurrency
    }

    private enum CodingKeys: String, CodingKey {
        case delimiter, hasHeader, dateColumn, amountColumn, accountColumn, currencyColumn
        case strongIDColumn, referenceColumn, descriptionColumn, runningBalanceColumn
        case dateOrder, decimalSeparator, groupingSeparator, defaultAccount, defaultCurrency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func character(_ key: CodingKeys) throws -> Character {
            let value = try container.decode(String.self, forKey: key)
            guard value.count == 1, let character = value.first else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected exactly one Character")
            }
            return character
        }
        func optionalCharacter(_ key: CodingKeys) throws -> Character? {
            guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard value.count == 1, let character = value.first else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected exactly one Character")
            }
            return character
        }
        self.init(
            delimiter: try character(.delimiter),
            hasHeader: try container.decode(Bool.self, forKey: .hasHeader),
            dateColumn: try container.decode(Int.self, forKey: .dateColumn),
            amountColumn: try container.decode(Int.self, forKey: .amountColumn),
            accountColumn: try container.decodeIfPresent(Int.self, forKey: .accountColumn),
            currencyColumn: try container.decodeIfPresent(Int.self, forKey: .currencyColumn),
            strongIDColumn: try container.decodeIfPresent(Int.self, forKey: .strongIDColumn),
            referenceColumn: try container.decodeIfPresent(Int.self, forKey: .referenceColumn),
            descriptionColumn: try container.decodeIfPresent(Int.self, forKey: .descriptionColumn),
            runningBalanceColumn: try container.decodeIfPresent(Int.self, forKey: .runningBalanceColumn),
            dateOrder: try container.decode(DateOrder.self, forKey: .dateOrder),
            decimalSeparator: try character(.decimalSeparator),
            groupingSeparator: try optionalCharacter(.groupingSeparator),
            defaultAccount: try container.decodeIfPresent(String.self, forKey: .defaultAccount),
            defaultCurrency: try container.decodeIfPresent(String.self, forKey: .defaultCurrency)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(delimiter), forKey: .delimiter)
        try container.encode(hasHeader, forKey: .hasHeader)
        try container.encode(dateColumn, forKey: .dateColumn)
        try container.encode(amountColumn, forKey: .amountColumn)
        try container.encodeIfPresent(accountColumn, forKey: .accountColumn)
        try container.encodeIfPresent(currencyColumn, forKey: .currencyColumn)
        try container.encodeIfPresent(strongIDColumn, forKey: .strongIDColumn)
        try container.encodeIfPresent(referenceColumn, forKey: .referenceColumn)
        try container.encodeIfPresent(descriptionColumn, forKey: .descriptionColumn)
        try container.encodeIfPresent(runningBalanceColumn, forKey: .runningBalanceColumn)
        try container.encode(dateOrder, forKey: .dateOrder)
        try container.encode(String(decimalSeparator), forKey: .decimalSeparator)
        try container.encodeIfPresent(groupingSeparator.map(String.init), forKey: .groupingSeparator)
        try container.encodeIfPresent(defaultAccount, forKey: .defaultAccount)
        try container.encodeIfPresent(defaultCurrency, forKey: .defaultCurrency)
    }
}

public struct StructuredImportProfile: Hashable, Codable, Sendable {
    public let dateOrder: DateOrder
    public let decimalSeparator: String
    public let groupingSeparator: String?
    public let defaultAccount: String?
    public let defaultCurrency: String?

    public init(
        dateOrder: DateOrder = .ymd,
        decimalSeparator: String = ".",
        groupingSeparator: String? = nil,
        defaultAccount: String? = nil,
        defaultCurrency: String? = nil
    ) {
        self.dateOrder = dateOrder
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.defaultAccount = defaultAccount
        self.defaultCurrency = defaultCurrency
    }
}

public struct ParseReplayDescriptor: Hashable, Codable, Sendable {
    public let format: InputFormat
    public let parserVersion: String
    public let delimitedMapping: DelimitedMapping?
    public let selectedWorksheet: String?
    public let structuredProfile: StructuredImportProfile?
    public let balanceOverrides: [StatementBalance]

    public init(
        format: InputFormat,
        parserVersion: String,
        delimitedMapping: DelimitedMapping? = nil,
        selectedWorksheet: String? = nil,
        structuredProfile: StructuredImportProfile? = nil,
        balanceOverrides: [StatementBalance] = []
    ) {
        self.format = format
        self.parserVersion = parserVersion
        self.delimitedMapping = delimitedMapping
        self.selectedWorksheet = selectedWorksheet
        self.structuredProfile = structuredProfile
        self.balanceOverrides = balanceOverrides
    }
}

public struct SourceFileProof: Hashable, Codable, Sendable {
    public let sourceID: String
    public let filename: String
    public let byteCount: Int
    public let sha256: String

    public init(sourceID: String, filename: String, byteCount: Int, sha256: String) {
        self.sourceID = sourceID
        self.filename = filename
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct CanonicalTransaction: Equatable, Codable, Sendable {
    public let sourceID: String
    public let locator: String
    public let sourceOrdinal: Int
    public let account: String
    public let currency: CurrencyCode
    public let bookingDate: LocalDate
    public let valueDate: LocalDate?
    public let amount: ExactAmount
    public let runningBalance: ExactAmount?
    public let strongID: String?
    public let reference: String?
    public let payee: String?
    public let description: String?
    public let memo: String?
    public let transactionCode: String?
    public let clearedStatus: String?
    public let category: String?
    public let originalValues: [String: String]
    public let derivedFields: Set<String>

    public init(
        sourceID: String,
        locator: String,
        sourceOrdinal: Int = 0,
        account: String,
        currency: CurrencyCode,
        bookingDate: LocalDate,
        valueDate: LocalDate? = nil,
        amount: ExactAmount,
        runningBalance: ExactAmount? = nil,
        strongID: String? = nil,
        reference: String? = nil,
        payee: String? = nil,
        description: String? = nil,
        memo: String? = nil,
        transactionCode: String? = nil,
        clearedStatus: String? = nil,
        category: String? = nil,
        originalValues: [String: String] = [:],
        derivedFields: Set<String> = []
    ) {
        self.sourceID = sourceID
        self.locator = locator
        self.sourceOrdinal = sourceOrdinal
        self.account = account
        self.currency = currency
        self.bookingDate = bookingDate
        self.valueDate = valueDate
        self.amount = amount
        self.runningBalance = runningBalance
        self.strongID = strongID
        self.reference = reference
        self.payee = payee
        self.description = description
        self.memo = memo
        self.transactionCode = transactionCode
        self.clearedStatus = clearedStatus
        self.category = category
        self.originalValues = originalValues
        self.derivedFields = derivedFields
    }
}

public enum StatementBalanceKind: String, Codable, Sendable, Hashable { case opening, closing }

public struct StatementBalance: Hashable, Codable, Sendable {
    public let kind: StatementBalanceKind
    public let account: String
    public let currency: CurrencyCode
    public let date: LocalDate
    public let amount: ExactAmount
    public let locator: String

    public init(kind: StatementBalanceKind, account: String, currency: CurrencyCode, date: LocalDate, amount: ExactAmount, locator: String) {
        self.kind = kind
        self.account = account
        self.currency = currency
        self.date = date
        self.amount = amount
        self.locator = locator
    }
}

public struct SourceStatement: Equatable, Codable, Sendable {
    public let role: SourceRole
    public let file: SourceFileProof
    public let replay: ParseReplayDescriptor
    public let period: ReconciliationPeriod
    public let transactions: [CanonicalTransaction]
    public let balances: [StatementBalance]
    public let completeness: SourceCompleteness
    public let warnings: [String]
    public let invalidLocators: [String]

    public init(
        role: SourceRole,
        file: SourceFileProof,
        replay: ParseReplayDescriptor,
        period: ReconciliationPeriod,
        transactions: [CanonicalTransaction],
        balances: [StatementBalance] = [],
        completeness: SourceCompleteness = .complete,
        warnings: [String] = [],
        invalidLocators: [String] = []
    ) {
        self.role = role
        self.file = file
        self.replay = replay
        self.period = period
        self.transactions = transactions
        self.balances = balances
        self.completeness = completeness
        self.warnings = warnings
        self.invalidLocators = invalidLocators
    }
}

public enum MatchKind: String, Codable, Sendable, Hashable { case strongID, exactComposite, fuzzy, manual }

public struct TransactionMatch: Hashable, Codable, Sendable {
    public let leftLocator: String
    public let rightLocator: String
    public let kind: MatchKind

    public init(leftLocator: String, rightLocator: String, kind: MatchKind) {
        self.leftLocator = leftLocator
        self.rightLocator = rightLocator
        self.kind = kind
    }
}

public enum ExceptionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case missingFromLedger
    case unexpectedLedgerItem
    case deletedFromNewerExport
    case addedToNewerExport
    case duplicateInLeft
    case duplicateInRight
    case amountChanged
    case dateChanged
    case descriptionOrReferenceChanged
    case statusOrCategoryChanged
    case possibleSplitOrMerge
    case currencyOrAccountMismatch
    case balanceDifference
    case runningBalanceBreak
    case periodGapOrOverlap
    case invalidRow
    case ambiguousCandidate
}

public struct ReconciliationException: Hashable, Codable, Sendable {
    public let kind: ExceptionKind
    public let leftLocators: [String]
    public let rightLocators: [String]
    public let sourceFingerprints: [String]
    public let detail: String

    public init(
        kind: ExceptionKind,
        leftLocators: [String] = [],
        rightLocators: [String] = [],
        sourceFingerprints: [String] = [],
        detail: String
    ) {
        self.kind = kind
        self.leftLocators = leftLocators.sorted()
        self.rightLocators = rightLocators.sorted()
        self.sourceFingerprints = sourceFingerprints.sorted()
        self.detail = detail
    }
}

public struct UserDecision: Hashable, Codable, Sendable {
    public let exceptionKey: String
    public let explanation: String
    public let approved: Bool

    public init(exceptionKey: String, explanation: String, approved: Bool) {
        self.exceptionKey = exceptionKey
        self.explanation = explanation
        self.approved = approved
    }
}

public struct ManualMatchDecision: Hashable, Codable, Sendable {
    public let leftLocator: String
    public let rightLocator: String
    public let leftFingerprint: String
    public let rightFingerprint: String

    public init(leftLocator: String, rightLocator: String, leftFingerprint: String, rightFingerprint: String) {
        self.leftLocator = leftLocator
        self.rightLocator = rightLocator
        self.leftFingerprint = leftFingerprint
        self.rightFingerprint = rightFingerprint
    }
}

public enum ResultState: String, Codable, Sendable, Hashable { case reconciled, reconciledWithExplanations, differenceFound, cannotConclude }

public struct PartitionKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let account: String
    public let currency: CurrencyCode

    public init(account: String, currency: CurrencyCode) {
        self.account = account
        self.currency = currency
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.account, lhs.currency) < (rhs.account, rhs.currency)
    }

    public var description: String { "\(account)|\(currency.value)" }
}

public enum PartitionTotalKind: String, Codable, Sendable, Hashable {
    case sourceActivityComparison
    case statementBalanceEquation
}

public struct PartitionTotal: Hashable, Codable, Sendable {
    public let partition: PartitionKey
    public let kind: PartitionTotalKind
    public let left: ExactAmount
    public let right: ExactAmount
    public let difference: ExactAmount

    public init(partition: PartitionKey, kind: PartitionTotalKind, left: ExactAmount, right: ExactAmount, difference: ExactAmount) {
        self.partition = partition
        self.kind = kind
        self.left = left
        self.right = right
        self.difference = difference
    }
}

public struct ReconciliationResult: Hashable, Codable, Sendable {
    public let state: ResultState
    public let matches: [TransactionMatch]
    public let exceptions: [ReconciliationException]
    public let totals: [PartitionTotal]

    public init(state: ResultState, matches: [TransactionMatch], exceptions: [ReconciliationException], totals: [PartitionTotal]) {
        self.state = state
        self.matches = matches
        self.exceptions = exceptions
        self.totals = totals
    }
}

public struct ReconciliationJob: Equatable, Codable, Sendable {
    public let id: UUID
    public let mode: ReconciliationMode
    public let period: ReconciliationPeriod
    public let sources: [SourceStatement]
    public let matchingPolicy: MatchingPolicy?
    public let manualMatches: [ManualMatchDecision]
    public let decisions: [UserDecision]

    public init(
        id: UUID = UUID(),
        mode: ReconciliationMode,
        period: ReconciliationPeriod,
        sources: [SourceStatement],
        matchingPolicy: MatchingPolicy? = .default,
        manualMatches: [ManualMatchDecision] = [],
        decisions: [UserDecision] = []
    ) {
        self.id = id
        self.mode = mode
        self.period = period
        self.sources = sources
        self.matchingPolicy = matchingPolicy
        self.manualMatches = manualMatches
        self.decisions = decisions
    }
}
