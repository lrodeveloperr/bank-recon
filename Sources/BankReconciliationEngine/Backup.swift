import Foundation

public struct BackupJobHistory: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let revisions: [StoredJob]

    public init(jobID: UUID, revisions: [StoredJob]) {
        self.jobID = jobID
        self.revisions = revisions
    }
}

public struct EngineBackupPayload: Codable, Sendable, Equatable {
    public let createdAt: String
    public let engineVersion: String
    public let jobs: [BackupJobHistory]

    public init(createdAt: String, engineVersion: String, jobs: [BackupJobHistory]) {
        self.createdAt = createdAt
        self.engineVersion = engineVersion
        self.jobs = jobs
    }
}

public struct EngineBackupEnvelope: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maximumBytes = 256 * 1_024 * 1_024
    public static let maximumJobs = 10_000
    public static let maximumRevisionsPerJob = 10_000

    public let schemaVersion: Int
    public let payload: EngineBackupPayload
    public let payloadSHA256: String

    public init(payload: EngineBackupPayload, payloadSHA256: String) {
        self.schemaVersion = Self.schemaVersion
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
    }
}
