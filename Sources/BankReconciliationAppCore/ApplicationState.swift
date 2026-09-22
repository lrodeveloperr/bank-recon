import BankReconciliationEngine
import Foundation

public struct ReconciliationWorkspace: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var brandedEvidenceHeader: String?

    public init(id: UUID = UUID(), name: String, brandedEvidenceHeader: String? = nil) {
        self.id = id
        self.name = name
        self.brandedEvidenceHeader = brandedEvidenceHeader
    }
}

public struct SourceProfile: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var format: InputFormat
    public var delimitedMapping: DelimitedMapping?
    public var selectedWorksheet: String?
    public var structuredProfile: StructuredImportProfile?

    public init(
        id: UUID = UUID(),
        name: String,
        format: InputFormat,
        delimitedMapping: DelimitedMapping? = nil,
        selectedWorksheet: String? = nil,
        structuredProfile: StructuredImportProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.delimitedMapping = delimitedMapping
        self.selectedWorksheet = selectedWorksheet
        self.structuredProfile = structuredProfile
    }
}

public struct WatchedBatchFolder: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var bookmarkData: Data

    public init(id: UUID = UUID(), name: String, bookmarkData: Data) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
    }
}

public struct PersistedApplicationState: Codable, Sendable, Equatable {
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public var workspaces: [ReconciliationWorkspace]
    public var selectedWorkspaceID: UUID
    public var sourceProfiles: [SourceProfile]
    public var watchedBatchFolders: [WatchedBatchFolder]
    public var importedAtBySourceID: [String: String]
    public var workspaceIDByJobID: [String: UUID]
    public var preferredDateOrder: DateOrder
    public var preferredCurrency: String

    public init(
        workspaces: [ReconciliationWorkspace],
        selectedWorkspaceID: UUID,
        sourceProfiles: [SourceProfile] = [],
        watchedBatchFolders: [WatchedBatchFolder] = [],
        importedAtBySourceID: [String: String] = [:],
        workspaceIDByJobID: [String: UUID] = [:],
        preferredDateOrder: DateOrder = .ymd,
        preferredCurrency: String = "USD"
    ) {
        self.schemaVersion = Self.schemaVersion
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sourceProfiles = sourceProfiles
        self.watchedBatchFolders = watchedBatchFolders
        self.importedAtBySourceID = importedAtBySourceID
        self.workspaceIDByJobID = workspaceIDByJobID
        self.preferredDateOrder = preferredDateOrder
        self.preferredCurrency = preferredCurrency
    }

    public static func initial() -> Self {
        let workspace = ReconciliationWorkspace(name: "My entity")
        return Self(workspaces: [workspace], selectedWorkspaceID: workspace.id)
    }

    public var selectedWorkspace: ReconciliationWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    public func validate() throws {
        guard schemaVersion == PersistedApplicationState.schemaVersion,
              !workspaces.isEmpty,
              Set(workspaces.map(\.id)).count == workspaces.count,
              workspaces.contains(where: { $0.id == selectedWorkspaceID }),
              Set(sourceProfiles.map(\.id)).count == sourceProfiles.count,
              Set(watchedBatchFolders.map(\.id)).count == watchedBatchFolders.count,
              workspaceIDByJobID.keys.allSatisfy({ UUID(uuidString: $0) != nil && $0 == $0.lowercased() }),
              workspaceIDByJobID.values.allSatisfy({ id in workspaces.contains(where: { $0.id == id }) }),
              workspaces.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              sourceProfiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              watchedBatchFolders.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.bookmarkData.isEmpty
              }) else {
            throw EngineError.integrityFailure("application state is invalid")
        }
        _ = try CurrencyCode(preferredCurrency)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workspaces, selectedWorkspaceID, sourceProfiles, watchedBatchFolders
        case importedAtBySourceID, workspaceIDByJobID, preferredDateOrder, preferredCurrency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchema = try container.decode(Int.self, forKey: .schemaVersion)
        guard storedSchema == 2 || storedSchema == Self.schemaVersion else {
            throw EngineError.integrityFailure("unsupported application state schema")
        }
        self.schemaVersion = Self.schemaVersion
        self.workspaces = try container.decode([ReconciliationWorkspace].self, forKey: .workspaces)
        self.selectedWorkspaceID = try container.decode(UUID.self, forKey: .selectedWorkspaceID)
        self.sourceProfiles = try container.decodeIfPresent([SourceProfile].self, forKey: .sourceProfiles) ?? []
        self.watchedBatchFolders = try container.decodeIfPresent([WatchedBatchFolder].self, forKey: .watchedBatchFolders) ?? []
        self.importedAtBySourceID = try container.decodeIfPresent([String: String].self, forKey: .importedAtBySourceID) ?? [:]
        self.workspaceIDByJobID = try container.decodeIfPresent([String: UUID].self, forKey: .workspaceIDByJobID) ?? [:]
        self.preferredDateOrder = try container.decodeIfPresent(DateOrder.self, forKey: .preferredDateOrder) ?? .ymd
        self.preferredCurrency = try container.decodeIfPresent(String.self, forKey: .preferredCurrency) ?? "USD"
    }
}

public actor ApplicationStateRepository {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func load() throws -> PersistedApplicationState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .initial() }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw EngineError.integrityFailure("application state must be a regular file")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let state = try decoder.decode(PersistedApplicationState.self, from: data)
        try state.validate()
        return state
    }

    public func save(_ state: PersistedApplicationState) throws {
        try state.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

}

public struct ApplicationBackupPayload: Codable, Sendable, Equatable {
    public let createdAt: String
    public let engineBackup: Data
    public let applicationState: PersistedApplicationState

    public init(createdAt: String, engineBackup: Data, applicationState: PersistedApplicationState) {
        self.createdAt = createdAt
        self.engineBackup = engineBackup
        self.applicationState = applicationState
    }
}

public struct ApplicationBackupEnvelope: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maximumBytes = EngineBackupEnvelope.maximumBytes + 4 * 1_024 * 1_024

    public let schemaVersion: Int
    public let payload: ApplicationBackupPayload
    public let payloadSHA256: String

    public init(payload: ApplicationBackupPayload, payloadSHA256: String) {
        self.schemaVersion = Self.schemaVersion
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
    }
}

public enum ApplicationBackupCodec {
    public static func encode(payload: ApplicationBackupPayload) throws -> Data {
        let encoder = canonicalEncoder()
        let payloadData = try encoder.encode(payload)
        let envelope = ApplicationBackupEnvelope(payload: payload, payloadSHA256: Hashing.sha256(payloadData))
        let data = try encoder.encode(envelope)
        guard data.count <= ApplicationBackupEnvelope.maximumBytes else { throw EngineError.resourceLimit("application backup bytes") }
        return data
    }

    public static func decode(_ data: Data) throws -> ApplicationBackupPayload {
        guard data.count <= ApplicationBackupEnvelope.maximumBytes else { throw EngineError.resourceLimit("application backup bytes") }
        let envelope = try JSONDecoder().decode(ApplicationBackupEnvelope.self, from: data)
        guard envelope.schemaVersion == ApplicationBackupEnvelope.schemaVersion else {
            throw EngineError.integrityFailure("unsupported application backup schema")
        }
        let payloadData = try canonicalEncoder().encode(envelope.payload)
        guard Hashing.sha256(payloadData) == envelope.payloadSHA256 else {
            throw EngineError.integrityFailure("application backup digest mismatch")
        }
        return envelope.payload
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
