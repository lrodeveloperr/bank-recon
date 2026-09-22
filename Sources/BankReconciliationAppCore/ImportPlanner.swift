import BankReconciliationEngine
import Foundation

public struct ImportPlanner: Sendable {
    public init() {}

    public func format(data: Data, filename: String) throws -> InputFormat {
        let extensionName = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch extensionName {
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        case "xlsx": return .xlsx
        case "ofx": return .ofx
        case "qfx": return .qfx
        case "qbo": return .qbo
        case "qif": return .qif
        case "qmtf": return .qmtf
        case "mt940", "sta", "swift": return .mt940
        case "bai", "bai2": return .bai2
        case "xml":
            let prefix = String(decoding: data.prefix(131_072), as: UTF8.self).lowercased()
            if prefix.contains("camt.054.") || prefix.contains("bktocstmrdbtcdtntfctn") { return .camt054 }
            if prefix.contains("camt.053.") || prefix.contains("bktocstmrstmt") { return .camt053 }
            throw EngineError.unsupportedFormat(.camt053)
        default:
            let prefix = String(decoding: data.prefix(8_192), as: UTF8.self).uppercased()
            if prefix.contains("OFXHEADER:") || prefix.contains("<OFX") { return .ofx }
            if prefix.contains(":20:") && prefix.contains(":25:") { return .mt940 }
            if prefix.hasPrefix("01,") { return .bai2 }
            throw EngineError.invalidConfiguration("unsupported file extension: \(extensionName.isEmpty ? "none" : extensionName)")
        }
    }

    public func replayDescriptor(
        data: Data,
        filename: String,
        profile: SourceProfile? = nil,
        selectedWorksheet: String? = nil,
        defaultDateOrder: DateOrder,
        defaultCurrency: String
    ) throws -> ParseReplayDescriptor {
        let detected = try format(data: data, filename: filename)
        if let profile, profile.format != detected {
            throw EngineError.invalidConfiguration("selected source profile does not match \(detected.rawValue)")
        }
        let structured = profile?.structuredProfile ?? StructuredImportProfile(
            dateOrder: defaultDateOrder,
            defaultAccount: "Primary",
            defaultCurrency: defaultCurrency
        )
        switch detected {
        case .csv, .tsv:
            let mapping = profile?.delimitedMapping ?? (try inferredDelimitedMapping(
                data: data,
                format: detected,
                dateOrder: defaultDateOrder,
                defaultCurrency: defaultCurrency
            ))
            return ParseReplayDescriptor(format: detected, parserVersion: DelimitedParser.version, delimitedMapping: mapping)
        case .xlsx:
            let sheets = try XLSXParser().worksheetNames(data: data)
            let sheet = selectedWorksheet ?? profile?.selectedWorksheet ?? (sheets.count == 1 ? sheets[0] : nil)
            guard let sheet else {
                throw EngineError.invalidConfiguration("select one XLSX worksheet: \(sheets.joined(separator: ", "))")
            }
            let mapping = profile?.delimitedMapping ?? DelimitedMapping(
                delimiter: ",", hasHeader: true, dateColumn: 0, amountColumn: 1,
                accountColumn: 2, currencyColumn: 3, strongIDColumn: 4,
                referenceColumn: 5, descriptionColumn: 6, runningBalanceColumn: 7,
                dateOrder: defaultDateOrder, decimalSeparator: ".",
                defaultAccount: "Primary", defaultCurrency: defaultCurrency
            )
            return ParseReplayDescriptor(
                format: .xlsx, parserVersion: XLSXParser.version,
                delimitedMapping: mapping, selectedWorksheet: sheet
            )
        case .ofx, .qfx, .qbo:
            return ParseReplayDescriptor(format: detected, parserVersion: OFXParser.version, structuredProfile: structured)
        case .qif, .qmtf:
            return ParseReplayDescriptor(format: detected, parserVersion: QIFParser.version, structuredProfile: structured)
        case .camt053, .camt054:
            return ParseReplayDescriptor(format: detected, parserVersion: CAMTParser.version, structuredProfile: structured)
        case .mt940:
            return ParseReplayDescriptor(format: detected, parserVersion: MT940Parser.version, structuredProfile: structured)
        case .bai2:
            return ParseReplayDescriptor(format: detected, parserVersion: BAI2Parser.version, structuredProfile: structured)
        }
    }

    private func inferredDelimitedMapping(
        data: Data,
        format: InputFormat,
        dateOrder: DateOrder,
        defaultCurrency: String
    ) throws -> DelimitedMapping {
        guard let text = String(data: data.prefix(65_536), encoding: .utf8), !text.isEmpty else {
            throw EngineError.malformedInput("delimited file has no UTF-8 header")
        }
        let delimiter: Character
        if format == .tsv {
            delimiter = "\t"
        } else {
            let firstRecord = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
            let candidates: [Character] = [",", ";", "\t", "|"]
            delimiter = candidates.max { occurrences(of: $0, in: firstRecord) < occurrences(of: $1, in: firstRecord) } ?? ","
        }
        let headerLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let headers = parseHeader(headerLine, delimiter: delimiter).map(normalizeHeader)
        func index(_ aliases: Set<String>) -> Int? { headers.firstIndex(where: aliases.contains) }
        let date = index(["date", "transactiondate", "bookingdate", "posteddate", "datum", "buchungsdatum", "fecha", "fechacontable", "data"])
        let amount = index(["amount", "transactionamount", "montant", "betrag", "importe", "valor", "valore"])
        guard let date, let amount else {
            throw EngineError.invalidConfiguration("save a source profile because date and amount columns were not recognized")
        }
        let account = index(["account", "accountid", "accountnumber", "compte", "konto", "cuenta", "conta"])
        let currency = index(["currency", "currencycode", "devise", "wahrung", "moneda", "moeda"])
        let strongID = index(["id", "transactionid", "fitid", "uniqueid", "identifiant", "belegnummer"])
        let reference = index(["reference", "ref", "checknumber", "endtoendid", "referenz", "referencia"])
        let description = index(["description", "memo", "payee", "narrative", "libelle", "beschreibung", "descripcion", "descricao"])
        let balance = index(["balance", "runningbalance", "solde", "saldo", "kontostand"])
        return DelimitedMapping(
            delimiter: delimiter,
            hasHeader: true,
            dateColumn: date,
            amountColumn: amount,
            accountColumn: account,
            currencyColumn: currency,
            strongIDColumn: strongID,
            referenceColumn: reference,
            descriptionColumn: description,
            runningBalanceColumn: balance,
            dateOrder: dateOrder,
            decimalSeparator: ".",
            groupingSeparator: nil,
            defaultAccount: account == nil ? "Primary" : nil,
            defaultCurrency: currency == nil ? defaultCurrency : nil
        )
    }

    private func occurrences(of character: Character, in value: String) -> Int {
        value.reduce(into: 0) { if $1 == character { $0 += 1 } }
    }

    private func normalizeHeader(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private func parseHeader(_ value: String, delimiter: Character) -> [String] {
        var output: [String] = []
        var field = ""
        var quoted = false
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let character = value[cursor]
            if character == "\"" {
                let next = value.index(after: cursor)
                if quoted, next < value.endIndex, value[next] == "\"" {
                    field.append("\"")
                    cursor = next
                } else {
                    quoted.toggle()
                }
            } else if character == delimiter, !quoted {
                output.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
            cursor = value.index(after: cursor)
        }
        output.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return output
    }
}
