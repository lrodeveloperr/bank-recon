import Foundation
import XCTest
@testable import BankReconciliationAppCore
@testable import BankReconciliationEngine

final class AppCoreTests: XCTestCase {
    func testImportPlannerInfersNeutralLanguageCSVHeaders() throws {
        let planner = ImportPlanner()
        let data = Data("Fecha,Importe,Cuenta,Moneda,Referencia,Descripcion\n2026-01-02,10.00,A,EUR,R1,Pago\n".utf8)
        let replay = try planner.replayDescriptor(
            data: data,
            filename: "movimientos.csv",
            defaultDateOrder: .ymd,
            defaultCurrency: "EUR"
        )
        XCTAssertEqual(replay.format, .csv)
        XCTAssertEqual(replay.delimitedMapping?.dateColumn, 0)
        XCTAssertEqual(replay.delimitedMapping?.amountColumn, 1)
        XCTAssertEqual(replay.delimitedMapping?.accountColumn, 2)
        XCTAssertEqual(replay.delimitedMapping?.currencyColumn, 3)
    }

    func testApplicationBackupRoundTripContainsNoEntitlement() throws {
        let state = PersistedApplicationState.initial()
        let payload = ApplicationBackupPayload(
            createdAt: "2026-09-22T12:00:00Z",
            engineBackup: Data("engine".utf8),
            applicationState: state
        )
        let data = try ApplicationBackupCodec.encode(payload: payload)
        XCTAssertEqual(try ApplicationBackupCodec.decode(data), payload)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("verifiedProductIDs"))
        XCTAssertFalse(text.contains("com.worksbienstudios.bankreconciliation.pro"))
        XCTAssertFalse(text.contains("com.worksbienstudios.bankreconciliation.accountant"))
    }

    func testApplicationBackupDigestTamperingFails() throws {
        let payload = ApplicationBackupPayload(
            createdAt: "2026-09-22T12:00:00Z",
            engineBackup: Data("engine".utf8),
            applicationState: .initial()
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ApplicationBackupCodec.encode(payload: payload)) as? [String: Any])
        object["payloadSHA256"] = String(repeating: "0", count: 64)
        let changed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ApplicationBackupCodec.decode(changed)) { error in
            XCTAssertEqual(error as? EngineError, .integrityFailure("application backup digest mismatch"))
        }
    }

    func testEntitlementPolicyMatchesPublishedPlans() {
        let policy = EntitlementPolicy()
        XCTAssertTrue(policy.permitsLock(existingRealLocks: 1, tier: .free))
        XCTAssertFalse(policy.permitsLock(existingRealLocks: 2, tier: .free))
        XCTAssertTrue(policy.permitsLock(existingRealLocks: 10_000, tier: .pro))
        XCTAssertFalse(policy.permitsWorkspace(existingWorkspaceCount: 1, tier: .pro))
        XCTAssertTrue(policy.permitsWorkspace(existingWorkspaceCount: 1, tier: .accountant))
        XCTAssertFalse(policy.permitsBrandedEvidence(tier: .pro))
        XCTAssertTrue(policy.permitsBrandedEvidence(tier: .accountant))
    }

    func testApplicationStateRequiresValidEntityBindings() throws {
        var state = PersistedApplicationState.initial()
        let jobID = UUID().uuidString.lowercased()
        state.workspaceIDByJobID[jobID] = state.selectedWorkspaceID
        XCTAssertNoThrow(try state.validate())
        state.workspaceIDByJobID[jobID] = UUID()
        XCTAssertThrowsError(try state.validate())
    }

    func testSourceProfileDraftBuildsCompleteDelimitedMapping() throws {
        var draft = SourceProfileDraft(
            name: "Spanish bank CSV",
            format: .csv,
            dateOrder: .dmy,
            decimalSeparator: ",",
            groupingSeparator: ".",
            defaultAccount: "Operating",
            defaultCurrency: "EUR"
        )
        draft.delimiter = ";"
        draft.dateColumn = "1"
        draft.amountColumn = "4"
        draft.referenceColumn = "6"
        draft.runningBalanceColumn = "7"
        let profile = try draft.makeProfile()
        XCTAssertEqual(profile.name, "Spanish bank CSV")
        XCTAssertEqual(profile.delimitedMapping?.delimiter, ";")
        XCTAssertEqual(profile.delimitedMapping?.dateColumn, 1)
        XCTAssertEqual(profile.delimitedMapping?.amountColumn, 4)
        XCTAssertEqual(profile.delimitedMapping?.referenceColumn, 6)
        XCTAssertEqual(profile.delimitedMapping?.runningBalanceColumn, 7)
        XCTAssertEqual(profile.delimitedMapping?.defaultCurrency, "EUR")
    }

    func testSourceProfileDraftRejectsDuplicateColumns() {
        var draft = SourceProfileDraft(name: "Invalid")
        draft.dateColumn = "2"
        draft.amountColumn = "2"
        XCTAssertThrowsError(try draft.makeProfile())
    }

    func testSchemaTwoApplicationStateMigratesWithEmptyBatchFolders() throws {
        let data = try JSONEncoder().encode(PersistedApplicationState.initial())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "watchedBatchFolders")
        let migrated = try JSONDecoder().decode(
            PersistedApplicationState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(migrated.schemaVersion, PersistedApplicationState.schemaVersion)
        XCTAssertTrue(migrated.watchedBatchFolders.isEmpty)
        XCTAssertNoThrow(try migrated.validate())
    }

    func testBatchFolderScannerFindsAllSupportedNamingSets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filenames = [
            "august_bank.csv", "august_ledger.csv",
            "revision_old.csv", "revision_new.csv",
            "card_statement.ofx", "notes.txt", "orphan_bank.csv"
        ]
        for filename in filenames {
            try Data("stub".utf8).write(to: root.appendingPathComponent(filename))
        }
        let result = try BatchFolderScanner().scan(root)
        XCTAssertEqual(result.candidates.map(\.mode), [.bankVsLedger, .singleStatement, .exportVsExport])
        XCTAssertTrue(result.unassignedFilenames.contains("notes.txt"))
        XCTAssertTrue(result.unassignedFilenames.contains("orphan_bank.csv"))
    }

    func testBatchFolderScannerRejectsAmbiguousDuplicateRoles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-duplicates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for filename in ["month_bank.csv", "month_bank.ofx", "month_ledger.csv"] {
            try Data("stub".utf8).write(to: root.appendingPathComponent(filename))
        }
        let result = try BatchFolderScanner().scan(root)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(Set(result.unassignedFilenames), Set(["month_bank.csv", "month_bank.ofx", "month_ledger.csv"]))
    }
}
