import BankReconciliationEngine
import Foundation

public struct SourceProfileDraft: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var format: InputFormat
    public var hasHeader: Bool
    public var delimiter: String
    public var dateColumn: String
    public var amountColumn: String
    public var accountColumn: String
    public var currencyColumn: String
    public var strongIDColumn: String
    public var referenceColumn: String
    public var descriptionColumn: String
    public var runningBalanceColumn: String
    public var dateOrder: DateOrder
    public var decimalSeparator: String
    public var groupingSeparator: String
    public var defaultAccount: String
    public var defaultCurrency: String
    public var selectedWorksheet: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        format: InputFormat = .csv,
        hasHeader: Bool = true,
        delimiter: String = ",",
        dateColumn: String = "0",
        amountColumn: String = "1",
        accountColumn: String = "",
        currencyColumn: String = "",
        strongIDColumn: String = "",
        referenceColumn: String = "",
        descriptionColumn: String = "",
        runningBalanceColumn: String = "",
        dateOrder: DateOrder = .ymd,
        decimalSeparator: String = ".",
        groupingSeparator: String = "",
        defaultAccount: String = "Primary",
        defaultCurrency: String = "USD",
        selectedWorksheet: String = ""
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.hasHeader = hasHeader
        self.delimiter = delimiter
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
        self.selectedWorksheet = selectedWorksheet
    }

    public init(profile: SourceProfile) {
        let delimited = profile.delimitedMapping
        let structured = profile.structuredProfile
        self.init(
            id: profile.id,
            name: profile.name,
            format: profile.format,
            hasHeader: delimited?.hasHeader ?? true,
            delimiter: delimited.map { String($0.delimiter) } ?? (profile.format == .tsv ? "\t" : ","),
            dateColumn: delimited.map { String($0.dateColumn) } ?? "0",
            amountColumn: delimited.map { String($0.amountColumn) } ?? "1",
            accountColumn: delimited?.accountColumn.map(String.init) ?? "",
            currencyColumn: delimited?.currencyColumn.map(String.init) ?? "",
            strongIDColumn: delimited?.strongIDColumn.map(String.init) ?? "",
            referenceColumn: delimited?.referenceColumn.map(String.init) ?? "",
            descriptionColumn: delimited?.descriptionColumn.map(String.init) ?? "",
            runningBalanceColumn: delimited?.runningBalanceColumn.map(String.init) ?? "",
            dateOrder: delimited?.dateOrder ?? structured?.dateOrder ?? .ymd,
            decimalSeparator: delimited.map { String($0.decimalSeparator) } ?? structured?.decimalSeparator ?? ".",
            groupingSeparator: delimited?.groupingSeparator.map(String.init) ?? structured?.groupingSeparator ?? "",
            defaultAccount: delimited?.defaultAccount ?? structured?.defaultAccount ?? "",
            defaultCurrency: delimited?.defaultCurrency ?? structured?.defaultCurrency ?? "",
            selectedWorksheet: profile.selectedWorksheet ?? ""
        )
    }

    public var usesColumnMapping: Bool { format == .csv || format == .tsv || format == .xlsx }

    public func makeProfile() throws -> SourceProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw EngineError.invalidConfiguration("source profile name is required")
        }
        let currency = normalized(defaultCurrency)
        if let currency { _ = try CurrencyCode(currency) }
        let account = normalized(defaultAccount)
        let grouping = normalized(groupingSeparator)
        guard decimalSeparator.count == 1 else {
            throw EngineError.invalidConfiguration("decimal separator must be one character")
        }
        guard grouping == nil || grouping?.count == 1 else {
            throw EngineError.invalidConfiguration("grouping separator must be one character")
        }
        if let grouping, grouping == decimalSeparator {
            throw EngineError.invalidConfiguration("decimal and grouping separators must differ")
        }

        if usesColumnMapping {
            let separator = format == .tsv ? "\t" : delimiter
            guard separator.count == 1 else {
                throw EngineError.invalidConfiguration("delimiter must be one character")
            }
            let date = try requiredColumn(dateColumn, named: "date")
            let amount = try requiredColumn(amountColumn, named: "amount")
            let optionalColumns = try [
                optionalColumn(accountColumn, named: "account"),
                optionalColumn(currencyColumn, named: "currency"),
                optionalColumn(strongIDColumn, named: "transaction ID"),
                optionalColumn(referenceColumn, named: "reference"),
                optionalColumn(descriptionColumn, named: "description"),
                optionalColumn(runningBalanceColumn, named: "running balance")
            ]
            let columns = [date, amount] + optionalColumns.compactMap { $0 }
            guard Set(columns).count == columns.count else {
                throw EngineError.invalidConfiguration("each mapped field must use a different column")
            }
            let mapping = DelimitedMapping(
                delimiter: separator.first!,
                hasHeader: hasHeader,
                dateColumn: date,
                amountColumn: amount,
                accountColumn: optionalColumns[0],
                currencyColumn: optionalColumns[1],
                strongIDColumn: optionalColumns[2],
                referenceColumn: optionalColumns[3],
                descriptionColumn: optionalColumns[4],
                runningBalanceColumn: optionalColumns[5],
                dateOrder: dateOrder,
                decimalSeparator: decimalSeparator.first!,
                groupingSeparator: grouping?.first,
                defaultAccount: account,
                defaultCurrency: currency
            )
            return SourceProfile(
                id: id,
                name: normalizedName,
                format: format,
                delimitedMapping: mapping,
                selectedWorksheet: format == .xlsx ? normalized(selectedWorksheet) : nil
            )
        }

        return SourceProfile(
            id: id,
            name: normalizedName,
            format: format,
            structuredProfile: StructuredImportProfile(
                dateOrder: dateOrder,
                decimalSeparator: decimalSeparator,
                groupingSeparator: grouping,
                defaultAccount: account,
                defaultCurrency: currency
            )
        )
    }

    private func requiredColumn(_ value: String, named name: String) throws -> Int {
        guard let column = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), column >= 0 else {
            throw EngineError.invalidConfiguration("\(name) column must be zero or greater")
        }
        return column
    }

    private func optionalColumn(_ value: String, named name: String) throws -> Int? {
        guard let value = normalized(value) else { return nil }
        guard let column = Int(value), column >= 0 else {
            throw EngineError.invalidConfiguration("\(name) column must be blank or zero or greater")
        }
        return column
    }

    private func normalized(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
