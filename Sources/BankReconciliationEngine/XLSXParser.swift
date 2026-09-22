import Foundation

public struct XLSXParser: Sendable {
    public static let version = "xlsx-1.0.0"
    public let limits: ParserLimits

    public init(limits: ParserLimits = ParserLimits()) { self.limits = limits }

    public func worksheetNames(data: Data) throws -> [String] {
        let archive = try BoundedZIPArchive(data: data, limits: limits)
        let workbook = try BoundedXMLTree.parse(archive.data(for: "xl/workbook.xml"), limits: limits)
        return try workbookSheets(workbook).map(\.name)
    }

    public func parse(
        data: Data,
        filename: String,
        role: SourceRole,
        period: ReconciliationPeriod,
        replay: ParseReplayDescriptor
    ) throws -> SourceStatement {
        guard replay.format == .xlsx else { throw EngineError.unsupportedFormat(replay.format) }
        guard replay.parserVersion == Self.version else {
            throw EngineError.invalidConfiguration("unsupported XLSX parser version: \(replay.parserVersion)")
        }
        guard let mapping = replay.delimitedMapping else { throw EngineError.invalidConfiguration("XLSX requires a bound column mapping") }
        guard let selectedWorksheet = replay.selectedWorksheet, !selectedWorksheet.isEmpty else {
            throw EngineError.invalidConfiguration("XLSX requires an explicitly selected worksheet")
        }
        try validate(mapping: mapping)

        let archive = try BoundedZIPArchive(data: data, limits: limits)
        for required in ["[Content_Types].xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"] where !archive.contains(required) {
            throw EngineError.malformedInput("XLSX is missing \(required)")
        }
        let workbook = try BoundedXMLTree.parse(archive.data(for: "xl/workbook.xml"), limits: limits)
        let relationships = try BoundedXMLTree.parse(archive.data(for: "xl/_rels/workbook.xml.rels"), limits: limits)
        let sheets = try workbookSheets(workbook)
        guard Set(sheets.map(\.name)).count == sheets.count else { throw EngineError.malformedInput("XLSX contains duplicate worksheet names") }
        guard let sheet = sheets.first(where: { $0.name == selectedWorksheet }) else {
            throw EngineError.notFound("worksheet \(selectedWorksheet)")
        }
        let relationshipNodes = relationships.children(named: "Relationship")
        var targets: [String: String] = [:]
        for relationship in relationshipNodes {
            guard let identifier = relationship.attributes["Id"] ?? relationship.attributes["id"],
                  let target = relationship.attributes["Target"] ?? relationship.attributes["target"] else {
                throw EngineError.malformedInput("XLSX workbook relationship is incomplete")
            }
            guard relationship.attributes["TargetMode"]?.lowercased() != "external" else {
                throw EngineError.malformedInput("external XLSX relationships are forbidden")
            }
            guard targets[identifier] == nil else { throw EngineError.malformedInput("duplicate XLSX relationship identifier") }
            targets[identifier] = try worksheetPath(target)
        }
        guard let sheetPath = targets[sheet.relationshipID], archive.contains(sheetPath) else {
            throw EngineError.malformedInput("selected XLSX worksheet relationship is missing")
        }

        let sharedStrings = archive.contains("xl/sharedStrings.xml")
            ? try parseSharedStrings(archive.data(for: "xl/sharedStrings.xml")) : []
        let dateStyles = archive.contains("xl/styles.xml")
            ? try parseDateStyles(archive.data(for: "xl/styles.xml")) : []
        let date1904 = workbook.first(named: "workbookPr")?.attributes["date1904"]?.lowercased() == "true" ||
            workbook.first(named: "workbookPr")?.attributes["date1904"] == "1"
        let worksheet = try BoundedXMLTree.parse(archive.data(for: sheetPath), limits: limits)
        let rows = try parseRows(worksheet, sharedStrings: sharedStrings)
        guard !rows.isEmpty else { throw EngineError.malformedInput("selected XLSX worksheet is empty") }
        let dataRows = mapping.hasHeader ? Array(rows.dropFirst()) : rows
        let identity = SourceIdentity(data: data)
        var transactions: [CanonicalTransaction] = []
        transactions.reserveCapacity(dataRows.count)
        let mappedColumns = requiredColumns(mapping)

        for row in dataRows where !row.cells.isEmpty {
            guard mappedColumns.allSatisfy({ row.cells[$0] != nil }) else {
                throw EngineError.malformedInput("XLSX row \(row.number) is missing a mapped cell")
            }
            for column in mappedColumns where row.cells[column]?.containsFormula == true {
                throw EngineError.malformedInput("XLSX mapped cell contains a formula at row \(row.number), column \(column)")
            }
            guard let dateCell = row.cells[mapping.dateColumn], let amountCell = row.cells[mapping.amountColumn] else {
                throw EngineError.malformedInput("XLSX row \(row.number) lacks date or amount")
            }
            let date = try parseDateCell(dateCell, dateStyles: dateStyles, date1904: date1904, order: mapping.dateOrder)
            guard period.contains(date) else {
                throw EngineError.periodViolation("XLSX row \(row.number): \(date) is outside \(period.start)...\(period.end)")
            }
            let amount = try ExactAmount(
                parsing: amountCell.value,
                decimalSeparator: mapping.decimalSeparator,
                groupingSeparator: mapping.groupingSeparator
            )
            let (account, accountDerived) = try mappedOrDefault(row, column: mapping.accountColumn, fallback: mapping.defaultAccount, label: "account")
            let (currencyRaw, currencyDerived) = try mappedOrDefault(row, column: mapping.currencyColumn, fallback: mapping.defaultCurrency, label: "currency")
            let runningBalance: ExactAmount?
            if let column = mapping.runningBalanceColumn, let raw = nonempty(row.cells[column]?.value) {
                runningBalance = try ExactAmount(parsing: raw, decimalSeparator: mapping.decimalSeparator, groupingSeparator: mapping.groupingSeparator)
            } else {
                runningBalance = nil
            }
            var derived: Set<String> = []
            if accountDerived { derived.insert("account") }
            if currencyDerived { derived.insert("currency") }
            let originals = Dictionary(uniqueKeysWithValues: row.cells.sorted(by: { $0.key < $1.key }).map {
                ("column:\($0.key)", $0.value.value)
            })
            transactions.append(CanonicalTransaction(
                sourceID: identity.sourceID,
                locator: "sheet:\(selectedWorksheet)!row:\(row.number)",
                sourceOrdinal: transactions.count,
                account: account,
                currency: try CurrencyCode(currencyRaw),
                bookingDate: date,
                amount: amount,
                runningBalance: runningBalance,
                strongID: optional(row, column: mapping.strongIDColumn),
                reference: optional(row, column: mapping.referenceColumn),
                description: optional(row, column: mapping.descriptionColumn),
                originalValues: originals,
                derivedFields: derived
            ))
        }
        guard transactions.count <= limits.maximumRecords else { throw EngineError.resourceLimit("XLSX transaction records") }
        return SourceStatement(
            role: role,
            file: identity.proof(filename: filename, byteCount: data.count),
            replay: replay,
            period: period,
            transactions: transactions,
            balances: replay.balanceOverrides
        )
    }

    private struct WorkbookSheet {
        let name: String
        let relationshipID: String
    }

    private struct Cell {
        let value: String
        let type: String?
        let styleIndex: Int?
        let containsFormula: Bool
    }

    private struct Row {
        let number: Int
        let cells: [Int: Cell]
    }

    private func validate(mapping: DelimitedMapping) throws {
        guard mapping.dateColumn != mapping.amountColumn else { throw EngineError.invalidConfiguration("XLSX date and amount columns must differ") }
        let columns = requiredColumns(mapping)
        guard columns.allSatisfy({ $0 >= 0 && $0 < limits.maximumColumns }) else {
            throw EngineError.invalidConfiguration("XLSX mapping references an invalid column")
        }
    }

    private func requiredColumns(_ mapping: DelimitedMapping) -> [Int] {
        [mapping.dateColumn, mapping.amountColumn] + [
            mapping.accountColumn, mapping.currencyColumn, mapping.strongIDColumn,
            mapping.referenceColumn, mapping.descriptionColumn, mapping.runningBalanceColumn
        ].compactMap { $0 }
    }

    private func workbookSheets(_ workbook: BoundedXMLNode) throws -> [WorkbookSheet] {
        guard workbook.name == "workbook", let sheets = workbook.first(named: "sheets") else {
            throw EngineError.malformedInput("XLSX workbook structure is invalid")
        }
        return try sheets.children(named: "sheet").map { node in
            guard let name = node.attributes["name"], !name.isEmpty,
                  let relationshipID = node.attributes["r:id"] ?? node.attributes["id"], !relationshipID.isEmpty else {
                throw EngineError.malformedInput("XLSX worksheet declaration is incomplete")
            }
            return WorkbookSheet(name: name, relationshipID: relationshipID)
        }
    }

    private func worksheetPath(_ target: String) throws -> String {
        let candidate = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard candidate.hasPrefix("xl/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw EngineError.malformedInput("unsafe XLSX worksheet relationship")
        }
        return candidate
    }

    private func parseSharedStrings(_ data: Data) throws -> [String] {
        let root = try BoundedXMLTree.parse(data, limits: limits)
        guard root.name == "sst" else { throw EngineError.malformedInput("XLSX shared strings root is invalid") }
        let strings = root.children(named: "si").map { item in
            item.descendants(named: "t").map(\.recursiveText).joined()
        }
        guard strings.count <= limits.maximumRecords else { throw EngineError.resourceLimit("XLSX shared strings") }
        return strings
    }

    private func parseDateStyles(_ data: Data) throws -> [Bool] {
        let root = try BoundedXMLTree.parse(data, limits: limits)
        guard root.name == "styleSheet" else { throw EngineError.malformedInput("XLSX styles root is invalid") }
        var customFormats: [Int: String] = [:]
        for format in root.first(named: "numFmts")?.children(named: "numFmt") ?? [] {
            guard let idRaw = format.attributes["numFmtId"], let id = Int(idRaw),
                  let code = format.attributes["formatCode"] else {
                throw EngineError.malformedInput("XLSX number format is incomplete")
            }
            guard customFormats[id] == nil else { throw EngineError.malformedInput("duplicate XLSX number format") }
            customFormats[id] = code
        }
        guard let cellXfs = root.first(named: "cellXfs") else { return [] }
        return try cellXfs.children(named: "xf").map { style in
            guard let raw = style.attributes["numFmtId"], let id = Int(raw) else {
                throw EngineError.malformedInput("XLSX cell style lacks numFmtId")
            }
            if (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) { return true }
            guard let code = customFormats[id] else { return false }
            let scrubbed = code.lowercased()
                .replacingOccurrences(of: "\\\\.", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            return scrubbed.contains("y") || scrubbed.contains("d")
        }
    }

    private func parseRows(_ worksheet: BoundedXMLNode, sharedStrings: [String]) throws -> [Row] {
        guard worksheet.name == "worksheet", let sheetData = worksheet.first(named: "sheetData") else {
            throw EngineError.malformedInput("XLSX worksheet structure is invalid")
        }
        var output: [Row] = []
        var seenRows: Set<Int> = []
        for rowNode in sheetData.children(named: "row") {
            guard let rowRaw = rowNode.attributes["r"], let rowNumber = Int(rowRaw), rowNumber > 0,
                  seenRows.insert(rowNumber).inserted else {
                throw EngineError.malformedInput("XLSX row number is missing or duplicated")
            }
            var cells: [Int: Cell] = [:]
            for cellNode in rowNode.children(named: "c") {
                guard let reference = cellNode.attributes["r"], let column = columnIndex(reference), column < limits.maximumColumns,
                      cells[column] == nil else {
                    throw EngineError.malformedInput("XLSX cell reference is invalid or duplicated")
                }
                let type = cellNode.attributes["t"]
                let styleIndex = cellNode.attributes["s"].flatMap(Int.init)
                let formula = cellNode.first(named: "f") != nil
                let raw: String
                switch type {
                case "s":
                    guard let indexRaw = cellNode.first(named: "v")?.text, let index = Int(indexRaw), sharedStrings.indices.contains(index) else {
                        throw EngineError.malformedInput("XLSX shared-string index is invalid")
                    }
                    raw = sharedStrings[index]
                case "inlineStr":
                    guard let inline = cellNode.first(named: "is") else { throw EngineError.malformedInput("XLSX inline string is missing") }
                    raw = inline.descendants(named: "t").map(\.recursiveText).joined()
                case "str", "n", nil:
                    raw = cellNode.first(named: "v")?.text ?? ""
                case "b":
                    guard let value = cellNode.first(named: "v")?.text, value == "0" || value == "1" else {
                        throw EngineError.malformedInput("XLSX boolean cell is invalid")
                    }
                    raw = value == "1" ? "TRUE" : "FALSE"
                case "e":
                    throw EngineError.malformedInput("XLSX contains an error cell at \(reference)")
                default:
                    throw EngineError.malformedInput("unsupported XLSX cell type: \(type ?? "nil")")
                }
                guard raw.utf8.count <= limits.maximumFieldBytes else { throw EngineError.resourceLimit("XLSX cell bytes") }
                cells[column] = Cell(value: raw, type: type, styleIndex: styleIndex, containsFormula: formula)
            }
            output.append(Row(number: rowNumber, cells: cells))
            guard output.count <= limits.maximumRecords else { throw EngineError.resourceLimit("XLSX rows") }
        }
        return output.sorted { $0.number < $1.number }
    }

    private func columnIndex(_ reference: String) -> Int? {
        var value = 0
        var letterCount = 0
        for scalar in reference.unicodeScalars {
            if (65...90).contains(scalar.value) {
                value = value * 26 + Int(scalar.value - 64)
                letterCount += 1
            } else if (97...122).contains(scalar.value) {
                value = value * 26 + Int(scalar.value - 96)
                letterCount += 1
            } else if (48...57).contains(scalar.value) {
                continue
            } else {
                return nil
            }
        }
        return letterCount > 0 ? value - 1 : nil
    }

    private func parseDateCell(_ cell: Cell, dateStyles: [Bool], date1904: Bool, order: DateOrder) throws -> LocalDate {
        if cell.type == "n" || cell.type == nil {
            guard let style = cell.styleIndex, dateStyles.indices.contains(style), dateStyles[style] else {
                throw EngineError.malformedInput("numeric XLSX date cell lacks an explicit date style")
            }
            return try excelDate(cell.value, date1904: date1904)
        }
        return try StructuredValueParser.date(cell.value, order: order)
    }

    private func excelDate(_ raw: String, date1904: Bool) throws -> LocalDate {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let serial = Int(parts[0]), serial >= 0,
              parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            throw EngineError.invalidDate(raw)
        }
        let base: LocalDate
        let offset: Int
        if date1904 {
            base = try LocalDate(iso8601: "1904-01-01")
            offset = serial
        } else {
            guard serial != 60 else { throw EngineError.invalidDate("Excel's fictitious 1900-02-29") }
            base = try LocalDate(iso8601: "1899-12-31")
            offset = serial > 60 ? serial - 1 : serial
        }
        return try localDate(fromJulianDay: julianDay(base) + offset)
    }

    private func julianDay(_ date: LocalDate) -> Int {
        let a = (14 - date.month) / 12
        let y = date.year + 4_800 - a
        let m = date.month + (12 * a) - 3
        return date.day + ((153 * m + 2) / 5) + (365 * y) + (y / 4) - (y / 100) + (y / 400) - 32_045
    }

    private func localDate(fromJulianDay day: Int) throws -> LocalDate {
        let a = day + 32_044
        let b = (4 * a + 3) / 146_097
        let c = a - (146_097 * b) / 4
        let d = (4 * c + 3) / 1_461
        let e = c - (1_461 * d) / 4
        let m = (5 * e + 2) / 153
        let dateDay = e - (153 * m + 2) / 5 + 1
        let month = m + 3 - 12 * (m / 10)
        let year = 100 * b + d - 4_800 + m / 10
        return try LocalDate(year: year, month: month, day: dateDay)
    }

    private func optional(_ row: Row, column: Int?) -> String? {
        guard let column else { return nil }
        return nonempty(row.cells[column]?.value)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func mappedOrDefault(_ row: Row, column: Int?, fallback: String?, label: String) throws -> (String, Bool) {
        if let value = optional(row, column: column) { return (value, false) }
        guard let fallback = nonempty(fallback) else { throw EngineError.malformedInput("XLSX row \(row.number) is missing \(label)") }
        return (fallback, true)
    }
}
