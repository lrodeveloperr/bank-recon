import Foundation

public struct EvidenceReportPack: Sendable, Hashable {
    public let baseFilename: String
    public let pdf: Data
    public let csv: Data
    public let json: Data

    public init(baseFilename: String, pdf: Data, csv: Data, json: Data) {
        self.baseFilename = baseFilename
        self.pdf = pdf
        self.csv = csv
        self.json = json
    }
}

public struct EvidenceReportRenderer: Sendable {
    public init() {}

    public func render(
        record: StoredJob,
        entityName: String,
        importedAtBySourceID: [String: String] = [:],
        brandedHeader: String? = nil,
        entitlement: EntitlementTier = .free
    ) throws -> EvidenceReportPack {
        guard record.state == .locked, let result = record.result, let evidence = record.evidence else {
            throw EngineError.invalidConfiguration("evidence reports require a locked reconciliation")
        }
        let entity = entityName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entity.isEmpty else { throw EngineError.invalidConfiguration("entity name is required") }
        if let brandedHeader, !brandedHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !EntitlementPolicy().permitsBrandedEvidence(tier: entitlement) {
            throw EngineError.entitlementRequired(.accountant)
        }

        var lines: [String] = []
        if let brandedHeader, !brandedHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(brandedHeader.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines += [
            "BANK RECONCILIATION EVIDENCE PACK",
            "Entity: \(entity)",
            "Job: \(record.job.id.uuidString.lowercased())",
            "Mode: \(record.job.mode.rawValue)",
            "Period: \(record.job.period.start) to \(record.job.period.end)",
            "Result: \(result.state.rawValue)",
            "Locked: \(evidence.lockedAt)",
            "Engine: \(EvidenceLocker.engineVersion)",
            "Evidence: \(evidence.evidenceID)",
            "Manifest SHA-256: \(evidence.manifestSHA256)",
            "",
            "SOURCES"
        ]
        for source in record.job.sources.sorted(by: { $0.file.filename < $1.file.filename }) {
            lines.append("\(source.role.rawValue): \(source.file.filename)")
            lines.append("  source \(source.file.sourceID); \(source.file.byteCount) bytes; SHA-256 \(source.file.sha256)")
            lines.append("  parser \(source.replay.parserVersion); imported \(importedAtBySourceID[source.file.sourceID] ?? "not recorded")")
        }
        lines += ["", "TOTALS"]
        for total in result.totals {
            lines.append("\(total.partition): \(total.kind.rawValue); left \(total.left); right \(total.right); difference \(total.difference)")
        }
        lines += ["", "MATCHES: \(result.matches.count)"]
        for match in result.matches {
            lines.append("\(match.kind.rawValue): \(match.leftLocator) <-> \(match.rightLocator)")
        }
        lines += ["", "EXCEPTIONS: \(result.exceptions.count)"]
        let decisions = Dictionary(uniqueKeysWithValues: record.job.decisions.map { ($0.exceptionKey, $0) })
        let engine = ReconciliationEngine()
        for exception in result.exceptions {
            let key = engine.exceptionKey(exception)
            let decision = decisions[key]
            lines.append("\(exception.kind.rawValue): \(exception.detail)")
            lines.append("  left \(exception.leftLocators.joined(separator: " | ")); right \(exception.rightLocators.joined(separator: " | "))")
            if let decision {
                lines.append("  explanation \(decision.approved ? "approved" : "not approved"): \(decision.explanation)")
            }
        }
        lines += [
            "",
            "LIMITATION",
            "This report proves only the supplied files and recorded decisions; it is not bank, accounting, tax, legal or audit assurance."
        ]

        let base = "bank-reconciliation-\(record.job.period.end)-\(record.job.id.uuidString.lowercased().prefix(8))"
        return EvidenceReportPack(
            baseFilename: base,
            pdf: try SimplePDF.render(lines: lines),
            csv: csv(record: record, result: result, entity: entity, importedAtBySourceID: importedAtBySourceID),
            json: evidence.canonicalManifest
        )
    }

    private func csv(
        record: StoredJob,
        result: ReconciliationResult,
        entity: String,
        importedAtBySourceID: [String: String]
    ) -> Data {
        var rows: [[String]] = [["section", "type", "account", "currency", "left", "right", "difference", "details"]]
        rows.append(["summary", result.state.rawValue, "", "", "", "", "", entity])
        for source in record.job.sources.sorted(by: { $0.file.filename < $1.file.filename }) {
            rows.append([
                "source", source.role.rawValue, "", "", "", "", "",
                "\(source.file.filename) | \(source.file.sha256) | \(source.file.byteCount) bytes | \(source.replay.parserVersion) | \(importedAtBySourceID[source.file.sourceID] ?? "not recorded")"
            ])
        }
        for total in result.totals {
            rows.append([
                "total", total.kind.rawValue, total.partition.account, total.partition.currency.value,
                total.left.description, total.right.description, total.difference.description, ""
            ])
        }
        for match in result.matches {
            rows.append(["match", match.kind.rawValue, "", "", match.leftLocator, match.rightLocator, "", ""])
        }
        for exception in result.exceptions {
            rows.append([
                "exception", exception.kind.rawValue, "", "",
                exception.leftLocators.joined(separator: " | "),
                exception.rightLocators.joined(separator: " | "), "", exception.detail
            ])
        }
        let text = rows.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private enum SimplePDF {
    static func render(lines: [String]) throws -> Data {
        let sanitized = lines.map(ascii)
        let chunks = stride(from: 0, to: sanitized.count, by: 52).map {
            Array(sanitized[$0..<min($0 + 52, sanitized.count)])
        }
        let pages: [[String]] = chunks.isEmpty ? [[]] : chunks
        let fontObject = 3 + pages.count * 2
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        let kids = pages.indices.map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        for (index, pageLines) in pages.enumerated() {
            let pageObject = 3 + index * 2
            let contentObject = pageObject + 1
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(fontObject) 0 R >> >> /Contents \(contentObject) 0 R >>")
            let commands = (["BT", "/F1 9 Tf", "48 744 Td", "12 TL"] + pageLines.map { "(\(escape($0))) Tj T*" } + ["ET"]).joined(separator: "\n")
            objects.append("<< /Length \(commands.utf8.count) >>\nstream\n\(commands)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        var data = Data("%PDF-1.4\n%WorksBien\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        trailer += offsets.dropFirst().map { String(format: "%010d 00000 n \n", $0) }.joined()
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        data.append(Data(trailer.utf8))
        guard data.count <= 32 * 1_024 * 1_024 else { throw EngineError.resourceLimit("evidence PDF bytes") }
        return data
    }

    private static func ascii(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            scalar.value >= 32 && scalar.value <= 126 ? Character(String(scalar)) : "?"
        })
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}
