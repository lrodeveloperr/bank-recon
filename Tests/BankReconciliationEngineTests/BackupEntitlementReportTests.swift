import Foundation
import Dispatch
import Security
import XCTest
@testable import BankReconciliationEngine

private final class BackupTestAnchorStore: DurableStoreAnchor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "BankReconciliationEngineTests.BackupTestAnchorStore")
    private var values: [String: Data] = [:]
    private var failureCountdown: Int?

    func failCompareAndSwap(afterSuccessfulCalls count: Int) {
        queue.sync { failureCountdown = count }
    }

    func load(identifier: String) throws -> Data? {
        queue.sync { values[identifier] }
    }

    func compareAndSwap(identifier: String, expected: Data?, replacement: Data) throws {
        try queue.sync {
            if let countdown = failureCountdown {
                if countdown == 0 {
                    failureCountdown = nil
                    throw EngineError.integrityFailure("injected backup anchor failure")
                }
                failureCountdown = countdown - 1
            }
            guard values[identifier] == expected else {
                throw EngineError.integrityFailure("test anchor changed concurrently")
            }
            values[identifier] = replacement
        }
    }
}

final class BackupEntitlementReportTests: XCTestCase {
    func testFreeTierAllowsTwoRealLocksAndProAllowsNext() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())

        for index in 0..<3 {
            let bundle = try distinctSample()
            let draft = try await store.createDraft(bundle.job)
            let evidence = try makeEvidence(bundle, second: index)
            if index < 2 {
                _ = try await store.commitLock(
                    jobID: bundle.job.id,
                    expectedRevision: draft.revision,
                    result: bundle.result,
                    evidence: evidence
                )
            } else {
                do {
                    _ = try await store.commitLock(
                        jobID: bundle.job.id,
                        expectedRevision: draft.revision,
                        result: bundle.result,
                        evidence: evidence
                    )
                    XCTFail("the third free lock must require Pro")
                } catch {
                    XCTAssertEqual(error as? EngineError, .entitlementRequired(.pro))
                }
                _ = try await store.commitLock(
                    jobID: bundle.job.id,
                    expectedRevision: draft.revision,
                    result: bundle.result,
                    evidence: evidence,
                    entitlement: .pro
                )
            }
        }
        let counted = try await store.countedRealLocks()
        XCTAssertEqual(counted, 3)
    }

    func testBackupRoundTripPreservesLockedRecord() async throws {
        let sourceRoot = temporaryRoot()
        let targetRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let bundle = try distinctSample()
        let source = try FileEngineStore(root: sourceRoot, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())
        let draft = try await source.createDraft(bundle.job)
        let expected = try await source.commitLock(
            jobID: bundle.job.id,
            expectedRevision: draft.revision,
            result: bundle.result,
            evidence: makeEvidence(bundle, second: 0)
        )
        let backup = try await source.exportBackup(createdAt: "2026-09-22T12:00:00Z")

        let target = try FileEngineStore(root: targetRoot, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())
        let restoredCount = try await target.restoreBackup(backup)
        let restored = try await target.load(bundle.job.id)
        let counted = try await target.countedRealLocks()
        XCTAssertEqual(restoredCount, 1)
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(counted, 1)
    }

    func testBackupDigestTamperingFailsClosed() async throws {
        let root = temporaryRoot()
        let targetRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try await source.exportBackup(createdAt: "2026-09-22T12:00:00Z")
        ) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["engineVersion"] = "tampered"
        object["payload"] = payload
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let target = try FileEngineStore(root: targetRoot, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())
        do {
            _ = try await target.restoreBackup(tampered)
            XCTFail("tampered backup must fail")
        } catch {
            XCTAssertEqual(error as? EngineError, .integrityFailure("backup payload digest mismatch"))
        }
    }

    func testRestoreRecoversAfterFinalAnchorWriteFailure() async throws {
        let sourceRoot = temporaryRoot()
        let targetRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let bundle = try distinctSample()
        let source = try FileEngineStore(root: sourceRoot, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())
        _ = try await source.createDraft(bundle.job)
        let backup = try await source.exportBackup(createdAt: "2026-09-22T12:00:00Z")

        let anchors = BackupTestAnchorStore()
        anchors.failCompareAndSwap(afterSuccessfulCalls: 2)
        let target = try FileEngineStore(root: targetRoot, anchorIdentifier: UUID().uuidString, anchorStore: anchors)
        do {
            _ = try await target.restoreBackup(backup)
            XCTFail("injected final anchor failure should surface")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
        let recovered = try await target.load(bundle.job.id)
        XCTAssertEqual(recovered.job, bundle.job)
    }

    func testEvidenceReportExportsPDFCSVAndManifest() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try distinctSample()
        let store = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: BackupTestAnchorStore())
        let draft = try await store.createDraft(bundle.job)
        let record = try await store.commitLock(
            jobID: bundle.job.id,
            expectedRevision: draft.revision,
            result: bundle.result,
            evidence: makeEvidence(bundle, second: 0)
        )
        let pack = try EvidenceReportRenderer().render(
            record: record,
            entityName: "Acme Ltd",
            importedAtBySourceID: Dictionary(uniqueKeysWithValues: bundle.job.sources.map { ($0.file.sourceID, "2026-09-22T11:59:00Z") })
        )
        XCTAssertTrue(String(decoding: pack.pdf.prefix(8), as: UTF8.self).hasPrefix("%PDF-1.4"))
        XCTAssertTrue(String(decoding: pack.csv, as: UTF8.self).contains("Acme Ltd"))
        XCTAssertEqual(pack.json, record.evidence?.canonicalManifest)

        XCTAssertThrowsError(try EvidenceReportRenderer().render(
            record: record,
            entityName: "Acme Ltd",
            brandedHeader: "Acme Finance",
            entitlement: .free
        )) { error in
            XCTAssertEqual(error as? EngineError, .entitlementRequired(.accountant))
        }
        _ = try EvidenceReportRenderer().render(
            record: record,
            entityName: "Acme Ltd",
            brandedHeader: "Acme Finance",
            entitlement: .accountant
        )
    }

    func testKeychainAnchorCompareAndSwapIntegration() throws {
        let service = "com.worksbien.bank-reconciliation.tests.\(UUID().uuidString)"
        let identifier = UUID().uuidString
        let anchor = KeychainStoreAnchor(service: service)
        defer { deleteKeychainValue(service: service, identifier: identifier) }
        XCTAssertNil(try anchor.load(identifier: identifier))
        try anchor.compareAndSwap(identifier: identifier, expected: nil, replacement: Data("one".utf8))
        XCTAssertEqual(try anchor.load(identifier: identifier), Data("one".utf8))
        XCTAssertThrowsError(try anchor.compareAndSwap(
            identifier: identifier,
            expected: Data("wrong".utf8),
            replacement: Data("two".utf8)
        ))
        try anchor.compareAndSwap(
            identifier: identifier,
            expected: Data("one".utf8),
            replacement: Data("two".utf8)
        )
        XCTAssertEqual(try anchor.load(identifier: identifier), Data("two".utf8))
    }

    private func distinctSample() throws -> SampleFactory.SampleBundle {
        let sample = try SampleFactory.balancedModeA()
        let job = ReconciliationJob(
            id: UUID(),
            mode: sample.job.mode,
            period: sample.job.period,
            sources: sample.job.sources,
            matchingPolicy: sample.job.matchingPolicy
        )
        return SampleFactory.SampleBundle(
            job: job,
            result: try ReconciliationEngine().run(job),
            sourceBytesByID: sample.sourceBytesByID
        )
    }

    private func makeEvidence(_ bundle: SampleFactory.SampleBundle, second: Int) throws -> LockedEvidence {
        try EvidenceLocker().lock(
            job: bundle.job,
            result: bundle.result,
            sourceBytesByID: bundle.sourceBytesByID,
            lockedAt: String(format: "2026-09-22T12:00:%02dZ", second)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func deleteKeychainValue(service: String, identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
