import BankReconciliationEngine
import Combine
import Foundation

public struct ImportedWorkflowSource: Sendable, Identifiable {
    public var id: String { statement.file.sourceID }
    public let statement: SourceStatement
    public let bytes: Data
    public let importedAt: String

    public init(statement: SourceStatement, bytes: Data, importedAt: String) {
        self.statement = statement
        self.bytes = bytes
        self.importedAt = importedAt
    }
}

public struct ReconciliationWorkflow: Sendable, Identifiable {
    public let id: UUID
    public var mode: ReconciliationMode
    public var period: ReconciliationPeriod
    public var sources: [ImportedWorkflowSource]
    public var storedRevision: Int?
    public var result: ReconciliationResult?
    public var isBuiltInSample: Bool

    public init(
        id: UUID = UUID(),
        mode: ReconciliationMode,
        period: ReconciliationPeriod,
        sources: [ImportedWorkflowSource] = [],
        storedRevision: Int? = nil,
        result: ReconciliationResult? = nil,
        isBuiltInSample: Bool = false
    ) {
        self.id = id
        self.mode = mode
        self.period = period
        self.sources = sources
        self.storedRevision = storedRevision
        self.result = result
        self.isBuiltInSample = isBuiltInSample
    }

    public var requiredRoles: [SourceRole] {
        switch mode {
        case .bankVsLedger: [.bank, .ledger]
        case .exportVsExport: [.olderExport, .newerExport]
        case .singleStatement: [.statement]
        }
    }
}

@MainActor
public final class BankReconciliationAppModel: ObservableObject {
    @Published public private(set) var applicationState = PersistedApplicationState.initial()
    @Published public private(set) var entitlement = EntitlementSnapshot.unverifiedFree
    @Published public private(set) var products: [StoreProductDescriptor] = []
    @Published public private(set) var summaries: [JobSummary] = []
    @Published public private(set) var records: [StoredJob] = []
    @Published public private(set) var workflow: ReconciliationWorkflow?
    @Published public private(set) var isBusy = false
    @Published public var message: String?

    private let store: FileEngineStore
    private let stateRepository: ApplicationStateRepository
    private let entitlementProvider: any EntitlementProviding
    private let router: FormatRouter
    private let planner: ImportPlanner

    public init(
        store: FileEngineStore,
        stateRepository: ApplicationStateRepository,
        entitlementProvider: any EntitlementProviding,
        router: FormatRouter = FormatRouter(),
        planner: ImportPlanner = ImportPlanner()
    ) {
        self.store = store
        self.stateRepository = stateRepository
        self.entitlementProvider = entitlementProvider
        self.router = router
        self.planner = planner
    }

    public static func live() throws -> BankReconciliationAppModel {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw EngineError.invalidConfiguration("application support directory is unavailable")
        }
        let root = support.appendingPathComponent("BankReconciliationCSV", isDirectory: true)
        let store = try FileEngineStore(
            root: root.appendingPathComponent("EngineStore", isDirectory: true),
            anchorIdentifier: "com.worksbienstudios.bankreconciliation.primary-store"
        )
        return BankReconciliationAppModel(
            store: store,
            stateRepository: ApplicationStateRepository(url: root.appendingPathComponent("application-state.json")),
            entitlementProvider: StoreKitEntitlementService()
        )
    }

    public func start() async {
        await perform {
            self.applicationState = try await self.stateRepository.load()
            self.entitlement = await self.entitlementProvider.refresh()
            self.products = try await self.entitlementProvider.availableProducts()
            try await self.reloadRecords()
        }
    }

    public func beginWorkflow(mode: ReconciliationMode, start: LocalDate, end: LocalDate) throws {
        workflow = ReconciliationWorkflow(mode: mode, period: try ReconciliationPeriod(start: start, end: end))
    }

    public func clearWorkflow() { workflow = nil }

    public func loadBuiltInSample() async {
        await perform {
            let sample = try SampleFactory.balancedModeA()
            let stored: StoredJob
            if let existing = try? await self.store.load(sample.job.id) {
                stored = existing
            } else {
                stored = try await self.store.createBuiltInSample(sample.job)
            }
            let now = Self.timestamp()
            let imports = try sample.job.sources.map { source -> ImportedWorkflowSource in
                guard let bytes = sample.sourceBytesByID[source.file.sourceID] else {
                    throw EngineError.integrityFailure("sample source bytes are missing")
                }
                return ImportedWorkflowSource(statement: source, bytes: bytes, importedAt: now)
            }
            self.workflow = ReconciliationWorkflow(
                id: sample.job.id,
                mode: sample.job.mode,
                period: sample.job.period,
                sources: imports,
                storedRevision: stored.revision,
                result: sample.result,
                isBuiltInSample: true
            )
        }
    }

    public func importFile(
        data: Data,
        filename: String,
        role: SourceRole,
        profileID: UUID? = nil,
        selectedWorksheet: String? = nil
    ) async {
        await perform {
            guard var current = self.workflow else { throw EngineError.invalidConfiguration("start a reconciliation first") }
            guard current.requiredRoles.contains(role) else { throw EngineError.roleMismatch(role.rawValue) }
            let profile = profileID.flatMap { id in self.applicationState.sourceProfiles.first { $0.id == id } }
            let replay = try self.planner.replayDescriptor(
                data: data,
                filename: filename,
                profile: profile,
                selectedWorksheet: selectedWorksheet,
                defaultDateOrder: self.applicationState.preferredDateOrder,
                defaultCurrency: self.applicationState.preferredCurrency
            )
            let period = current.period
            let router = self.router
            let statement = try await Task.detached {
                try router.parse(data: data, filename: filename, role: role, period: period, replay: replay)
            }.value
            current.sources.removeAll { $0.statement.role == role }
            let timestamp = Self.timestamp()
            current.sources.append(ImportedWorkflowSource(statement: statement, bytes: data, importedAt: timestamp))
            current.sources.sort { $0.statement.role.rawValue < $1.statement.role.rawValue }
            current.result = nil
            self.workflow = current
            self.applicationState.importedAtBySourceID[statement.file.sourceID] = timestamp
            try await self.stateRepository.save(self.applicationState)
        }
    }

    public func preview() async {
        await perform {
            guard var current = self.workflow else { throw EngineError.invalidConfiguration("start a reconciliation first") }
            let job = ReconciliationJob(
                id: current.id,
                mode: current.mode,
                period: current.period,
                sources: current.sources.map(\.statement)
            )
            let result = try await Task.detached { try ReconciliationEngine().run(job) }.value
            let stored: StoredJob
            if let revision = current.storedRevision {
                guard !current.isBuiltInSample else {
                    current.result = result
                    self.workflow = current
                    return
                }
                stored = try await self.store.updateDraft(job, expectedRevision: revision)
            } else {
                stored = try await self.store.createDraft(job)
            }
            current.storedRevision = stored.revision
            current.result = result
            self.workflow = current
            try await self.reloadRecords()
        }
    }

    public func decide(exception: ReconciliationException, explanation: String, approved: Bool) async {
        await perform {
            guard var current = self.workflow, let revision = current.storedRevision else {
                throw EngineError.invalidConfiguration("preview the reconciliation before recording a decision")
            }
            guard !current.isBuiltInSample else { throw EngineError.invalidConfiguration("the built-in sample is immutable") }
            let engine = ReconciliationEngine()
            let key = engine.exceptionKey(exception)
            let existing = try await self.store.load(current.id)
            var decisions = existing.job.decisions.filter { $0.exceptionKey != key }
            decisions.append(UserDecision(exceptionKey: key, explanation: explanation, approved: approved))
            let job = ReconciliationJob(
                id: current.id,
                mode: current.mode,
                period: current.period,
                sources: current.sources.map(\.statement),
                manualMatches: existing.job.manualMatches,
                decisions: decisions,
                matchingPolicy: existing.job.matchingPolicy
            )
            let result = try await Task.detached { try ReconciliationEngine().run(job) }.value
            let stored = try await self.store.updateDraft(job, expectedRevision: revision)
            current.storedRevision = stored.revision
            current.result = result
            self.workflow = current
            try await self.reloadRecords()
        }
    }

    public func lockCurrent() async {
        await perform {
            guard var current = self.workflow, let result = current.result, let revision = current.storedRevision else {
                throw EngineError.invalidConfiguration("preview the reconciliation before locking")
            }
            self.entitlement = await self.entitlementProvider.refresh()
            let stored = try await self.store.load(current.id)
            let job = stored.job
            var bytes: [String: Data] = [:]
            for source in current.sources {
                guard bytes.updateValue(source.bytes, forKey: source.statement.file.sourceID) == nil else {
                    throw EngineError.integrityFailure("duplicate source identifier in workflow")
                }
            }
            let lockedAt = Self.timestamp()
            let evidence = try await Task.detached {
                try EvidenceLocker().lock(job: job, result: result, sourceBytesByID: bytes, lockedAt: lockedAt)
            }.value
            let locked = try await self.store.commitLock(
                jobID: current.id,
                expectedRevision: revision,
                result: result,
                evidence: evidence,
                entitlement: self.entitlement.tier
            )
            current.storedRevision = locked.revision
            self.workflow = current
            try await self.reloadRecords()
            self.message = "Reconciliation locked and evidence retained."
        }
    }

    public func purchase(_ tier: EntitlementTier) async {
        await perform {
            switch try await self.entitlementProvider.purchase(tier) {
            case .purchased(let snapshot): self.entitlement = snapshot
            case .pending: self.message = "Purchase pending approval."
            case .cancelled: self.message = "Purchase cancelled."
            }
        }
    }

    public func restorePurchases() async {
        await perform { self.entitlement = try await self.entitlementProvider.restore() }
    }

    public func addWorkspace(named name: String) async {
        await perform {
            self.entitlement = await self.entitlementProvider.refresh()
            guard EntitlementPolicy().permitsWorkspace(
                existingWorkspaceCount: self.applicationState.workspaces.count,
                tier: self.entitlement.tier
            ) else { throw EngineError.entitlementRequired(.accountant) }
            let workspace = ReconciliationWorkspace(name: name)
            self.applicationState.workspaces.append(workspace)
            self.applicationState.selectedWorkspaceID = workspace.id
            try await self.stateRepository.save(self.applicationState)
        }
    }

    public func updateSelectedWorkspace(name: String, brandedHeader: String?) async {
        await perform {
            guard let index = self.applicationState.workspaces.firstIndex(where: { $0.id == self.applicationState.selectedWorkspaceID }) else {
                throw EngineError.integrityFailure("selected workspace is missing")
            }
            if let brandedHeader, !brandedHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !EntitlementPolicy().permitsBrandedEvidence(tier: self.entitlement.tier) {
                throw EngineError.entitlementRequired(.accountant)
            }
            self.applicationState.workspaces[index].name = name
            self.applicationState.workspaces[index].brandedEvidenceHeader = brandedHeader
            try await self.stateRepository.save(self.applicationState)
        }
    }

    public func saveSourceProfile(_ profile: SourceProfile) async {
        await perform {
            self.entitlement = await self.entitlementProvider.refresh()
            let existing = self.applicationState.sourceProfiles.firstIndex { $0.id == profile.id }
            if existing == nil,
               !EntitlementPolicy().permitsSourceProfile(
                    existingProfileCount: self.applicationState.sourceProfiles.count,
                    tier: self.entitlement.tier
               ) { throw EngineError.entitlementRequired(.pro) }
            if let existing { self.applicationState.sourceProfiles[existing] = profile }
            else { self.applicationState.sourceProfiles.append(profile) }
            try await self.stateRepository.save(self.applicationState)
        }
    }

    public func evidenceReport(for record: StoredJob) throws -> EvidenceReportPack {
        let workspace = applicationState.selectedWorkspace ?? ReconciliationWorkspace(name: "My entity")
        return try EvidenceReportRenderer().render(
            record: record,
            entityName: workspace.name,
            importedAtBySourceID: applicationState.importedAtBySourceID,
            brandedHeader: workspace.brandedEvidenceHeader,
            entitlement: entitlement.tier
        )
    }

    public func makeBackup() async throws -> Data {
        let createdAt = Self.timestamp()
        let engineBackup = try await store.exportBackup(createdAt: createdAt)
        return try ApplicationBackupCodec.encode(payload: ApplicationBackupPayload(
            createdAt: createdAt,
            engineBackup: engineBackup,
            applicationState: applicationState
        ))
    }

    public func restoreBackup(_ data: Data) async {
        await perform {
            let payload = try ApplicationBackupCodec.decode(data)
            try payload.applicationState.validate()
            _ = try await self.store.restoreBackup(payload.engineBackup)
            try await self.stateRepository.save(payload.applicationState)
            self.applicationState = payload.applicationState
            try await self.reloadRecords()
            self.message = "Backup restored. App Store purchases were not changed."
        }
    }

    private func reloadRecords() async throws {
        summaries = try await store.list()
        var loaded: [StoredJob] = []
        for summary in summaries { loaded.append(try await store.load(summary.id)) }
        records = loaded.sorted { $0.job.id.uuidString < $1.job.id.uuidString }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
