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
}
