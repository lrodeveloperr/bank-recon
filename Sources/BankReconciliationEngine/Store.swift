import Darwin
import Foundation

public enum StoredJobState: String, Codable, Sendable, Hashable { case draft, locked }

public struct StoredJob: Codable, Sendable, Equatable {
    public let job: ReconciliationJob
    public let revision: Int
    public let predecessorSnapshotID: String?
    public let state: StoredJobState
    public let result: ReconciliationResult?
    public let evidence: LockedEvidence?
    public let usageReceiptID: String?
    public let isSample: Bool

    init(
        job: ReconciliationJob,
        revision: Int,
        predecessorSnapshotID: String?,
        state: StoredJobState,
        result: ReconciliationResult?,
        evidence: LockedEvidence?,
        usageReceiptID: String?,
        isSample: Bool
    ) {
        self.job = job
        self.revision = revision
        self.predecessorSnapshotID = predecessorSnapshotID
        self.state = state
        self.result = result
        self.evidence = evidence
        self.usageReceiptID = usageReceiptID
        self.isSample = isSample
    }
}

public struct JobSummary: Hashable, Codable, Sendable {
    public let id: UUID
    public let mode: ReconciliationMode
    public let revision: Int
    public let state: StoredJobState
    public let resultState: ResultState?

    public init(id: UUID, mode: ReconciliationMode, revision: Int, state: StoredJobState, resultState: ResultState?) {
        self.id = id
        self.mode = mode
        self.revision = revision
        self.state = state
        self.resultState = resultState
    }
}

public actor FileEngineStore {
    public static let freeRealLockLimit = EntitlementPolicy.freeLockedReconciliationLimit

    private let root: URL
    private let jobsRoot: URL
    private let lockURL: URL
    private let anchorStore: any DurableStoreAnchor
    private let anchorIdentifier: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, anchorIdentifier: String, anchorStore: any DurableStoreAnchor = KeychainStoreAnchor()) throws {
        guard !anchorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.invalidConfiguration("durable anchor identifier is required")
        }
        self.root = root.standardizedFileURL
        self.jobsRoot = root.appendingPathComponent("jobs", isDirectory: true).standardizedFileURL
        self.lockURL = root.appendingPathComponent(".engine-store.lock", isDirectory: false).standardizedFileURL
        self.anchorStore = anchorStore
        self.anchorIdentifier = anchorIdentifier
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: jobsRoot, withIntermediateDirectories: true)
        let values = try jobsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw EngineError.integrityFailure("jobs root must be a real directory")
        }
    }

    public func createDraft(_ job: ReconciliationJob) throws -> StoredJob {
        try createDraftRecord(job, isSample: false)
    }

    public func createBuiltInSample(_ job: ReconciliationJob) throws -> StoredJob {
        guard job == (try SampleFactory.balancedModeA().job) else {
            throw EngineError.integrityFailure("sample exemption is limited to the built-in immutable sample")
        }
        return try createDraftRecord(job, isSample: true)
    }

    private func createDraftRecord(_ job: ReconciliationJob, isSample: Bool) throws -> StoredJob {
        try withExclusiveRootLock {
            let anchor = try validatedAnchor()
            let directory = jobDirectory(job.id)
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw EngineError.integrityFailure("job already exists")
            }
            let record = StoredJob(
                job: job,
                revision: 1,
                predecessorSnapshotID: nil,
                state: .draft,
                result: nil,
                evidence: nil,
                usageReceiptID: nil,
                isSample: isSample
            )
            let snapshotID = try snapshotID(for: record)
            let pendingAnchor = try beginAnchoredMutation(anchor, record: record, snapshotID: snapshotID)
            let writtenID = try writeNewJob(record, destinationDirectory: directory)
            guard writtenID == snapshotID else { throw EngineError.integrityFailure("new-job snapshot hash changed during write") }
            try finalizeAnchoredMutation(pendingAnchor)
            return record
        }
    }

    public func updateDraft(_ job: ReconciliationJob, expectedRevision: Int) throws -> StoredJob {
        try withExclusiveRootLock {
            let anchor = try validatedAnchor()
            let history = try validatedHistory(job.id)
            guard let current = history.last?.record else { throw EngineError.notFound(job.id.uuidString) }
            guard current.revision == expectedRevision else { throw EngineError.staleRevision }
            guard current.state == .draft else { throw EngineError.lockedMutation }
            guard !current.isSample else {
                throw EngineError.integrityFailure("the built-in sample draft is immutable")
            }
            let record = StoredJob(
                job: job,
                revision: current.revision + 1,
                predecessorSnapshotID: history.last?.snapshotID,
                state: .draft,
                result: nil,
                evidence: nil,
                usageReceiptID: nil,
                isSample: current.isSample
            )
            let snapshotID = try snapshotID(for: record)
            let pendingAnchor = try beginAnchoredMutation(anchor, record: record, snapshotID: snapshotID)
            let writtenID = try write(record)
            guard writtenID == snapshotID else { throw EngineError.integrityFailure("draft snapshot hash changed during write") }
            try finalizeAnchoredMutation(pendingAnchor)
            return record
        }
    }

    public func commitLock(
        jobID: UUID,
        expectedRevision: Int,
        result: ReconciliationResult,
        evidence: LockedEvidence,
        entitlement: EntitlementTier = .free
    ) throws -> StoredJob {
        try withExclusiveRootLock {
            let anchor = try validatedAnchor()
            let history = try validatedHistory(jobID)
            guard let current = history.last?.record else { throw EngineError.notFound(jobID.uuidString) }
            guard current.revision == expectedRevision else { throw EngineError.staleRevision }
            guard current.state == .draft else { throw EngineError.lockedMutation }
            try EvidenceLocker().verify(evidence, job: current.job, result: result)
            guard try ReconciliationEngine().run(current.job) == result else {
                throw EngineError.integrityFailure("lock result no longer reproduces")
            }
            let receiptID = "lock-\(evidence.manifestSHA256.prefix(32))"
            let realLockedHeads = anchor.heads.values.filter { $0.state == .locked && !$0.isSample }
            guard !anchor.heads.values.compactMap(\.usageReceiptID).contains(receiptID) else {
                throw EngineError.integrityFailure("duplicate lock receipt")
            }
            if !current.isSample,
               !EntitlementPolicy().permitsLock(existingRealLocks: realLockedHeads.count, tier: entitlement) {
                throw EngineError.entitlementRequired(.pro)
            }
            let record = StoredJob(
                job: current.job,
                revision: current.revision + 1,
                predecessorSnapshotID: history.last?.snapshotID,
                state: .locked,
                result: result,
                evidence: evidence,
                usageReceiptID: receiptID,
                isSample: current.isSample
            )
            let snapshotID = try snapshotID(for: record)
            let pendingAnchor = try beginAnchoredMutation(anchor, record: record, snapshotID: snapshotID)
            let writtenID = try write(record)
            guard writtenID == snapshotID else { throw EngineError.integrityFailure("locked snapshot hash changed during write") }
            try finalizeAnchoredMutation(pendingAnchor)
            return record
        }
    }

    public func load(_ id: UUID) throws -> StoredJob {
        try withExclusiveRootLock {
            _ = try validatedAnchor()
            guard let record = try validatedHistory(id).last?.record else { throw EngineError.notFound(id.uuidString) }
            return record
        }
    }

    public func list() throws -> [JobSummary] {
        try withExclusiveRootLock {
            _ = try validatedAnchor()
            return try allLatestRecords().map {
                JobSummary(id: $0.job.id, mode: $0.job.mode, revision: $0.revision, state: $0.state, resultState: $0.result?.state)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    public func countedRealLocks() throws -> Int {
        try withExclusiveRootLock {
            let anchor = try validatedAnchor()
            return anchor.state.realLockCount
        }
    }

    public func exportBackup(createdAt: String) throws -> Data {
        try validateWholeSecondTimestamp(createdAt)
        return try withExclusiveRootLock {
            _ = try validatedAnchor()
            let directories = try FileManager.default.contentsOfDirectory(
                at: jobsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var jobs: [BackupJobHistory] = []
            for directory in directories {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let id = UUID(uuidString: directory.lastPathComponent) else {
                    throw EngineError.integrityFailure("invalid job directory during backup")
                }
                let revisions = try validatedHistory(id).map(\.record)
                jobs.append(BackupJobHistory(jobID: id, revisions: revisions))
            }
            let payload = EngineBackupPayload(
                createdAt: createdAt,
                engineVersion: EvidenceLocker.engineVersion,
                jobs: jobs
            )
            let payloadData = try encoder.encode(payload)
            let envelope = EngineBackupEnvelope(payload: payload, payloadSHA256: Hashing.sha256(payloadData))
            let data = try encoder.encode(envelope)
            guard data.count <= EngineBackupEnvelope.maximumBytes else {
                throw EngineError.resourceLimit("backup bytes")
            }
            return data
        }
    }

    @discardableResult
    public func restoreBackup(_ data: Data) throws -> Int {
        guard data.count <= EngineBackupEnvelope.maximumBytes else { throw EngineError.resourceLimit("backup bytes") }
        return try withExclusiveRootLock {
            let anchor = try validatedAnchor()
            guard anchor.heads.isEmpty else {
                throw EngineError.invalidConfiguration("restore requires an empty reconciliation store")
            }
            let envelope = try decoder.decode(EngineBackupEnvelope.self, from: data)
            guard envelope.schemaVersion == EngineBackupEnvelope.schemaVersion else {
                throw EngineError.integrityFailure("unsupported backup schema")
            }
            try validateWholeSecondTimestamp(envelope.payload.createdAt)
            let payloadData = try encoder.encode(envelope.payload)
            guard Hashing.sha256(payloadData) == envelope.payloadSHA256 else {
                throw EngineError.integrityFailure("backup payload digest mismatch")
            }
            guard envelope.payload.jobs.count <= EngineBackupEnvelope.maximumJobs else {
                throw EngineError.resourceLimit("backup jobs")
            }
            let heads = try validateBackupJobs(envelope.payload.jobs)

            let token = UUID().uuidString.lowercased()
            let stagingRoot = root.appendingPathComponent(".restore-stage-\(token)", isDirectory: true)
            let stagedJobs = stagingRoot.appendingPathComponent("jobs", isDirectory: true)
            let backupName = ".jobs-before-restore-\(token)"
            let oldJobs = root.appendingPathComponent(backupName, isDirectory: true)
            try FileManager.default.createDirectory(at: stagedJobs, withIntermediateDirectories: true)
            var replaced = false
            defer {
                try? FileManager.default.removeItem(at: stagingRoot)
                if replaced { try? FileManager.default.removeItem(at: oldJobs) }
            }
            for history in envelope.payload.jobs.sorted(by: { $0.jobID.uuidString < $1.jobID.uuidString }) {
                let directory = stagedJobs.appendingPathComponent(history.jobID.uuidString.lowercased(), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                for record in history.revisions.sorted(by: { $0.revision < $1.revision }) {
                    let bytes = try encoder.encode(record)
                    let destination = directory.appendingPathComponent(revisionFilename(record.revision))
                    try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
                }
            }

            let pending = try beginAnchoredReplacement(anchor, heads: heads)
            _ = try FileManager.default.replaceItemAt(
                jobsRoot,
                withItemAt: stagedJobs,
                backupItemName: backupName,
                options: []
            )
            replaced = true
            try finalizeAnchoredMutation(pending)
            return envelope.payload.jobs.count
        }
    }

    private struct AnchorHead: Codable, Equatable {
        let revision: Int
        let snapshotID: String
        let state: StoredJobState
        let isSample: Bool
        let usageReceiptID: String?
    }

    private struct AnchorState: Codable, Equatable {
        var schemaVersion: Int
        var sequence: Int
        var headsSHA256: String
        var receiptsSHA256: String
        var realLockCount: Int
        var pending: PendingAnchorMutation?
    }

    private struct PendingAnchorMutation: Codable, Equatable {
        let headsSHA256: String
        let receiptsSHA256: String
        let realLockCount: Int
    }

    private struct AnchorContext {
        let state: AnchorState
        let encoded: Data
        let heads: [String: AnchorHead]
    }

    private struct HistoryItem {
        let record: StoredJob
        let snapshotID: String
    }

    private func validatedAnchor() throws -> AnchorContext {
        let stored = try anchorStore.load(identifier: anchorIdentifier)
        let actualHeads = try currentHeads()
        if stored == nil {
            guard actualHeads.isEmpty else {
                throw EngineError.integrityFailure("durable store anchor is missing for existing jobs")
            }
            let summary = try anchorSummary(actualHeads)
            let initial = AnchorState(
                schemaVersion: 3,
                sequence: 0,
                headsSHA256: summary.headsSHA256,
                receiptsSHA256: summary.receiptsSHA256,
                realLockCount: summary.realLockCount,
                pending: nil
            )
            let encoded = try encoder.encode(initial)
            try anchorStore.compareAndSwap(identifier: anchorIdentifier, expected: nil, replacement: encoded)
            return AnchorContext(state: initial, encoded: encoded, heads: actualHeads)
        }
        guard let stored else { throw EngineError.integrityFailure("durable store anchor disappeared") }
        let state = try decoder.decode(AnchorState.self, from: stored)
        guard state.schemaVersion == 3,
              state.sequence >= 0,
              state.realLockCount >= 0 else {
            throw EngineError.integrityFailure("durable store anchor does not match snapshot heads")
        }
        let actualSummary = try anchorSummary(actualHeads)
        if let pending = state.pending {
            if actualSummary.matches(state) {
                var cleared = state
                cleared.pending = nil
                let encoded = try encoder.encode(cleared)
                try anchorStore.compareAndSwap(identifier: anchorIdentifier, expected: stored, replacement: encoded)
                return AnchorContext(state: cleared, encoded: encoded, heads: actualHeads)
            }
            if actualSummary.matches(pending) {
                var completed = state
                completed.sequence += 1
                completed.headsSHA256 = pending.headsSHA256
                completed.receiptsSHA256 = pending.receiptsSHA256
                completed.realLockCount = pending.realLockCount
                completed.pending = nil
                let encoded = try encoder.encode(completed)
                try anchorStore.compareAndSwap(identifier: anchorIdentifier, expected: stored, replacement: encoded)
                return AnchorContext(state: completed, encoded: encoded, heads: actualHeads)
            }
            throw EngineError.integrityFailure("pending anchored mutation does not match the snapshot tree")
        }
        guard actualSummary.matches(state) else {
            throw EngineError.integrityFailure("durable store anchor does not match snapshot heads")
        }
        return AnchorContext(state: state, encoded: stored, heads: actualHeads)
    }

    private func currentHeads() throws -> [String: AnchorHead] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var heads: [String: AnchorHead] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let id = UUID(uuidString: url.lastPathComponent),
                  let latest = try validatedHistory(id).last else {
                throw EngineError.integrityFailure("invalid job directory while validating durable anchor")
            }
            heads[id.uuidString.lowercased()] = AnchorHead(
                revision: latest.record.revision,
                snapshotID: latest.snapshotID,
                state: latest.record.state,
                isSample: latest.record.isSample,
                usageReceiptID: latest.record.usageReceiptID
            )
        }
        return heads
    }

    private func beginAnchoredMutation(_ context: AnchorContext, record: StoredJob, snapshotID: String) throws -> AnchorContext {
        var state = context.state
        guard state.pending == nil else { throw EngineError.integrityFailure("another anchored mutation is pending") }
        let jobID = record.job.id.uuidString.lowercased()
        let nextHead = AnchorHead(
            revision: record.revision,
            snapshotID: snapshotID,
            state: record.state,
            isSample: record.isSample,
            usageReceiptID: record.usageReceiptID
        )
        var nextHeads = context.heads
        nextHeads[jobID] = nextHead
        let summary = try anchorSummary(nextHeads)
        state.pending = PendingAnchorMutation(
            headsSHA256: summary.headsSHA256,
            receiptsSHA256: summary.receiptsSHA256,
            realLockCount: summary.realLockCount
        )
        let encoded = try encoder.encode(state)
        try anchorStore.compareAndSwap(identifier: anchorIdentifier, expected: context.encoded, replacement: encoded)
        return AnchorContext(state: state, encoded: encoded, heads: context.heads)
    }

    private func beginAnchoredReplacement(_ context: AnchorContext, heads: [String: AnchorHead]) throws -> AnchorContext {
        var state = context.state
        guard state.pending == nil else { throw EngineError.integrityFailure("another anchored mutation is pending") }
        let summary = try anchorSummary(heads)
        state.pending = PendingAnchorMutation(
            headsSHA256: summary.headsSHA256,
            receiptsSHA256: summary.receiptsSHA256,
            realLockCount: summary.realLockCount
        )
        let encoded = try encoder.encode(state)
        try anchorStore.compareAndSwap(identifier: anchorIdentifier, expected: context.encoded, replacement: encoded)
        return AnchorContext(state: state, encoded: encoded, heads: context.heads)
    }

    private func finalizeAnchoredMutation(_ context: AnchorContext) throws {
        guard let pending = context.state.pending else { throw EngineError.integrityFailure("anchored mutation is not pending") }
        var state = context.state
        state.sequence += 1
        state.headsSHA256 = pending.headsSHA256
        state.receiptsSHA256 = pending.receiptsSHA256
        state.realLockCount = pending.realLockCount
        state.pending = nil
        let encoded = try encoder.encode(state)
        try anchorStore.compareAndSwap(identifier: anchorIdentifier, expected: context.encoded, replacement: encoded)
    }

    private func snapshotID(for record: StoredJob) throws -> String {
        Hashing.sha256(try encoder.encode(record))
    }

    private func validateBackupJobs(_ jobs: [BackupJobHistory]) throws -> [String: AnchorHead] {
        guard Set(jobs.map(\.jobID)).count == jobs.count else {
            throw EngineError.integrityFailure("backup contains duplicate jobs")
        }
        var heads: [String: AnchorHead] = [:]
        var receiptIDs: Set<String> = []
        for history in jobs {
            guard !history.revisions.isEmpty,
                  history.revisions.count <= EngineBackupEnvelope.maximumRevisionsPerJob else {
                throw EngineError.resourceLimit("backup job revisions")
            }
            var previousID: String?
            var previousState: StoredJobState?
            for (offset, record) in history.revisions.enumerated() {
                guard record.job.id == history.jobID,
                      record.revision == offset + 1,
                      record.predecessorSnapshotID == previousID,
                      previousState != .locked else {
                    throw EngineError.integrityFailure("backup revision chain is invalid")
                }
                switch record.state {
                case .draft:
                    guard record.result == nil, record.evidence == nil, record.usageReceiptID == nil else {
                        throw EngineError.integrityFailure("backup draft contains lock material")
                    }
                case .locked:
                    guard let result = record.result, let evidence = record.evidence,
                          record.usageReceiptID == "lock-\(evidence.manifestSHA256.prefix(32))" else {
                        throw EngineError.integrityFailure("backup lock material is incomplete")
                    }
                    try EvidenceLocker().verify(evidence, job: record.job, result: result)
                    guard let receiptID = record.usageReceiptID, receiptIDs.insert(receiptID).inserted else {
                        throw EngineError.integrityFailure("backup contains duplicate lock receipts")
                    }
                }
                previousID = try snapshotID(for: record)
                previousState = record.state
            }
            guard let latest = history.revisions.last, let snapshotID = previousID else {
                throw EngineError.integrityFailure("backup job has no latest revision")
            }
            heads[history.jobID.uuidString.lowercased()] = AnchorHead(
                revision: latest.revision,
                snapshotID: snapshotID,
                state: latest.state,
                isSample: latest.isSample,
                usageReceiptID: latest.usageReceiptID
            )
        }
        return heads
    }

    private func validateWholeSecondTimestamp(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 20,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes[19] == 90,
              bytes.enumerated().allSatisfy({ pair in
                  [4, 7, 10, 13, 16, 19].contains(pair.offset) || (48...57).contains(pair.element)
              }),
              let hour = Int(String(decoding: bytes[11..<13], as: UTF8.self)),
              let minute = Int(String(decoding: bytes[14..<16], as: UTF8.self)),
              let second = Int(String(decoding: bytes[17..<19], as: UTF8.self)),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw EngineError.invalidConfiguration("backup timestamp must be whole-second UTC RFC 3339")
        }
        _ = try LocalDate(iso8601: String(decoding: bytes[0..<10], as: UTF8.self))
    }

    private struct AnchorSummary {
        let headsSHA256: String
        let receiptsSHA256: String
        let realLockCount: Int

        func matches(_ state: AnchorState) -> Bool {
            headsSHA256 == state.headsSHA256 && receiptsSHA256 == state.receiptsSHA256 && realLockCount == state.realLockCount
        }

        func matches(_ pending: PendingAnchorMutation) -> Bool {
            headsSHA256 == pending.headsSHA256 && receiptsSHA256 == pending.receiptsSHA256 && realLockCount == pending.realLockCount
        }
    }

    private func anchorSummary(_ heads: [String: AnchorHead]) throws -> AnchorSummary {
        let headData = try encoder.encode(heads)
        let receipts = heads.values.compactMap { $0.state == .locked ? $0.usageReceiptID : nil }.sorted()
        let receiptData = try encoder.encode(receipts)
        return AnchorSummary(
            headsSHA256: Hashing.sha256(headData),
            receiptsSHA256: Hashing.sha256(receiptData),
            realLockCount: heads.values.filter { $0.state == .locked && !$0.isSample }.count
        )
    }

    private func validatedHistory(_ id: UUID) throws -> [HistoryItem] {
        let directory = jobDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw EngineError.integrityFailure("job path must be a real directory")
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var history: [HistoryItem] = []
        for (offset, url) in urls.enumerated() {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw EngineError.integrityFailure("non-regular snapshot file")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let record = try decoder.decode(StoredJob.self, from: data)
            guard record.job.id == id, record.revision == offset + 1,
                  url.lastPathComponent == revisionFilename(record.revision) else {
                throw EngineError.integrityFailure("revision sequence mismatch")
            }
            if let previous = history.last {
                guard record.predecessorSnapshotID == previous.snapshotID else {
                    throw EngineError.integrityFailure("predecessor snapshot mismatch")
                }
                if previous.record.state == .locked { throw EngineError.integrityFailure("revision exists after lock") }
            } else if record.predecessorSnapshotID != nil {
                throw EngineError.integrityFailure("first revision has a predecessor")
            }
            switch record.state {
            case .draft:
                guard record.result == nil, record.evidence == nil, record.usageReceiptID == nil else {
                    throw EngineError.integrityFailure("draft contains lock material")
                }
            case .locked:
                guard let evidence = record.evidence,
                      record.result != nil,
                      record.usageReceiptID == "lock-\(evidence.manifestSHA256.prefix(32))" else {
                    throw EngineError.integrityFailure("locked revision is incomplete")
                }
                guard let result = record.result else { throw EngineError.integrityFailure("locked result is missing") }
                try EvidenceLocker().verify(evidence, job: record.job, result: result)
            }
            history.append(HistoryItem(record: record, snapshotID: Hashing.sha256(data)))
        }
        return history
    }

    private func allLatestRecords() throws -> [StoredJob] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var records: [StoredJob] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let id = UUID(uuidString: url.lastPathComponent) else {
                throw EngineError.integrityFailure("unexpected entry in jobs directory")
            }
            guard let current = try validatedHistory(id).last?.record else {
                throw EngineError.integrityFailure("job directory has no revision")
            }
            records.append(current)
        }
        return records
    }

    private func write(_ record: StoredJob) throws -> String {
        let data = try encoder.encode(record)
        let destination = jobDirectory(record.job.id).appendingPathComponent(revisionFilename(record.revision))
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw EngineError.integrityFailure("revision already exists")
        }
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        return Hashing.sha256(data)
    }

    private func writeNewJob(_ record: StoredJob, destinationDirectory: URL) throws -> String {
        let staging = jobsRoot.appendingPathComponent(".stage-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let data = try encoder.encode(record)
        let revision = staging.appendingPathComponent(revisionFilename(record.revision))
        try data.write(to: revision, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.moveItem(at: staging, to: destinationDirectory)
        return Hashing.sha256(data)
    }

    private func jobDirectory(_ id: UUID) -> URL {
        jobsRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func revisionFilename(_ revision: Int) -> String {
        String(format: "revision-%08d.json", revision)
    }

    private func withExclusiveRootLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw EngineError.integrityFailure("cannot open store lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw EngineError.integrityFailure("cannot acquire store lock") }
        defer { flock(descriptor, LOCK_UN) }
        let values = try jobsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw EngineError.integrityFailure("jobs root must remain a real directory")
        }
        return try operation()
    }
}
