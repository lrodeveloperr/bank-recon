import BankReconciliationEngine
import Foundation

public struct BatchCandidate: Sendable, Hashable, Identifiable {
    public let name: String
    public let mode: ReconciliationMode
    public let filenamesByRole: [SourceRole: String]

    public init(name: String, mode: ReconciliationMode, filenamesByRole: [SourceRole: String]) {
        self.name = name
        self.mode = mode
        self.filenamesByRole = filenamesByRole
    }

    public var id: String {
        "\(mode.rawValue):\(name.lowercased()):" + filenamesByRole
            .map { "\($0.key.rawValue)=\($0.value.lowercased())" }
            .sorted()
            .joined(separator: "|")
    }
}

public struct BatchFolderScanResult: Sendable, Equatable {
    public let candidates: [BatchCandidate]
    public let unassignedFilenames: [String]

    public init(candidates: [BatchCandidate], unassignedFilenames: [String]) {
        self.candidates = candidates
        self.unassignedFilenames = unassignedFilenames
    }
}

public struct BatchFolderScanner: Sendable {
    public static let maximumFileCount = 1_000
    public static let maximumTotalBytes = 512 * 1_024 * 1_024

    private static let supportedExtensions: Set<String> = [
        "csv", "tsv", "tab", "xlsx", "ofx", "qfx", "qbo", "qif", "qmtf",
        "xml", "mt940", "sta", "swift", "bai", "bai2"
    ]

    public init() {}

    public func scan(_ folderURL: URL) throws -> BatchFolderScanResult {
        let folderValues = try folderURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
            throw EngineError.invalidConfiguration("batch folder must be a directory and not a symbolic link")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        guard urls.count <= Self.maximumFileCount else { throw EngineError.resourceLimit("batch folder file count") }

        var totalBytes = 0
        var grouped: [String: [SourceRole: [String]]] = [:]
        var unassigned: [String] = []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let filename = url.lastPathComponent
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                unassigned.append(filename)
                continue
            }
            let size = values.fileSize ?? 0
            let addition = totalBytes.addingReportingOverflow(size)
            guard !addition.overflow, addition.partialValue <= Self.maximumTotalBytes else {
                throw EngineError.resourceLimit("batch folder total bytes")
            }
            totalBytes = addition.partialValue
            guard let parsed = Self.classify(url.deletingPathExtension().lastPathComponent) else {
                unassigned.append(filename)
                continue
            }
            grouped[parsed.base, default: [:]][parsed.role, default: []].append(filename)
        }

        var candidates: [BatchCandidate] = []
        for base in grouped.keys.sorted() {
            guard let roles = grouped[base] else { continue }
            if Self.isExactPair(roles, .bank, .ledger) {
                candidates.append(BatchCandidate(
                    name: base, mode: .bankVsLedger,
                    filenamesByRole: [.bank: roles[.bank]![0], .ledger: roles[.ledger]![0]]
                ))
            } else if Self.isExactPair(roles, .olderExport, .newerExport) {
                candidates.append(BatchCandidate(
                    name: base, mode: .exportVsExport,
                    filenamesByRole: [.olderExport: roles[.olderExport]![0], .newerExport: roles[.newerExport]![0]]
                ))
            } else if roles.count == 1, roles[.statement]?.count == 1 {
                candidates.append(BatchCandidate(
                    name: base, mode: .singleStatement,
                    filenamesByRole: [.statement: roles[.statement]![0]]
                ))
            } else {
                unassigned.append(contentsOf: roles.values.flatMap { $0 })
            }
        }
        return BatchFolderScanResult(candidates: candidates, unassignedFilenames: unassigned.sorted())
    }

    private static func isExactPair(_ roles: [SourceRole: [String]], _ left: SourceRole, _ right: SourceRole) -> Bool {
        roles.count == 2 && roles[left]?.count == 1 && roles[right]?.count == 1
    }

    private static func classify(_ stem: String) -> (base: String, role: SourceRole)? {
        let suffixes: [(String, SourceRole)] = [
            ("_statement", .statement), ("_ledger", .ledger), ("_newer", .newerExport),
            ("_older", .olderExport), ("_bank", .bank), ("_new", .newerExport), ("_old", .olderExport)
        ]
        let lowercased = stem.lowercased()
        guard let match = suffixes.first(where: { lowercased.hasSuffix($0.0) }) else { return nil }
        let end = stem.index(stem.endIndex, offsetBy: -match.0.count)
        let base = String(stem[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : (base, match.1)
    }
}

public enum BatchFolderAccess {
    public static func makeBookmark(for url: URL) throws -> Data {
#if canImport(Darwin)
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
#else
        Data(url.standardizedFileURL.path.utf8)
#endif
    }

    public static func resolve(_ folder: WatchedBatchFolder) throws -> URL {
#if canImport(Darwin)
        var stale = false
        let url = try URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw EngineError.invalidConfiguration("batch folder permission is stale; add the folder again") }
        return url
#else
        guard let path = String(data: folder.bookmarkData, encoding: .utf8), !path.isEmpty else {
            throw EngineError.integrityFailure("batch folder bookmark is invalid")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
#endif
    }

    public static func startAccessing(_ url: URL) -> Bool {
#if canImport(Darwin)
        url.startAccessingSecurityScopedResource()
#else
        false
#endif
    }

    public static func stopAccessing(_ url: URL, whenGranted granted: Bool) {
#if canImport(Darwin)
        if granted { url.stopAccessingSecurityScopedResource() }
#endif
    }

    public static func fileURL(named filename: String, in folderURL: URL) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.contains("/"), !filename.contains("\\") else {
            throw EngineError.integrityFailure("unsafe batch filename")
        }
        let standardizedFolder = folderURL.standardizedFileURL
        let candidate = standardizedFolder.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedFolder else {
            throw EngineError.integrityFailure("batch file escapes selected folder")
        }
        return candidate
    }
}
