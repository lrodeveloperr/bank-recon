import Foundation
import Dispatch
import XCTest
@testable import BankReconciliationEngine

private final class TestAnchorStore: DurableStoreAnchor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "BankReconciliationEngineTests.TestAnchorStore")
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
                    throw EngineError.integrityFailure("injected anchor failure")
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

final class StoreTests: XCTestCase {
    func testPendingAnchorRecoversAfterFinalAnchorWriteFailure() async throws {
        let sample = try SampleFactory.balancedModeA()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let anchors = TestAnchorStore()
        let identifier = UUID().uuidString
        let store = try FileEngineStore(root: root, anchorIdentifier: identifier, anchorStore: anchors)
        let draft = try await store.createDraft(sample.job)
        anchors.failCompareAndSwap(afterSuccessfulCalls: 1)
        do {
            _ = try await store.updateDraft(sample.job, expectedRevision: draft.revision)
            XCTFail("injected final anchor failure should surface")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
        let recovered = try await store.load(sample.job.id)
        XCTAssertEqual(recovered.revision, 2)
        XCTAssertEqual(recovered.state, .draft)
    }

    func testJobDirectorySymlinkIsRejected() async throws {
        let sample = try SampleFactory.balancedModeA()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: TestAnchorStore())
        _ = try await store.createDraft(sample.job)
        let jobPath = root.appendingPathComponent("jobs", isDirectory: true).appendingPathComponent(sample.job.id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.moveItem(at: jobPath, to: outside)
        try FileManager.default.createSymbolicLink(at: jobPath, withDestinationURL: outside)
        do {
            _ = try await store.load(sample.job.id)
            XCTFail("job directory symlink must fail")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
    }

    func testBuiltInSampleCannotCarryExemptionToAnotherJob() async throws {
        let sample = try SampleFactory.balancedModeA()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: TestAnchorStore())
        let draft = try await store.createBuiltInSample(sample.job)
        let replacement = ReconciliationJob(
            id: sample.job.id,
            mode: sample.job.mode,
            period: sample.job.period,
            sources: sample.job.sources,
            decisions: [UserDecision(exceptionKey: "arbitrary", explanation: "changed", approved: true)]
        )
        do {
            _ = try await store.updateDraft(replacement, expectedRevision: draft.revision)
            XCTFail("sample draft must be immutable")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
    }

    func testLockIsAppendOnlyAndCounted() async throws {
        let sample = try SampleFactory.balancedModeA()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: TestAnchorStore())
        let draft = try await store.createDraft(sample.job)
        let evidence = try EvidenceLocker().lock(
            job: sample.job,
            result: sample.result,
            sourceBytesByID: sample.sourceBytesByID,
            lockedAt: "2026-09-22T00:00:00Z"
        )
        let locked = try await store.commitLock(
            jobID: sample.job.id,
            expectedRevision: draft.revision,
            result: sample.result,
            evidence: evidence
        )
        XCTAssertEqual(locked.state, .locked)
        let counted = try await store.countedRealLocks()
        XCTAssertEqual(counted, 1)
        do {
            _ = try await store.commitLock(
                jobID: sample.job.id,
                expectedRevision: locked.revision,
                result: sample.result,
                evidence: evidence
            )
            XCTFail("second lock should fail")
        } catch {
            XCTAssertEqual(error as? EngineError, .lockedMutation)
        }
        let lockedRevision = root
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(sample.job.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("revision-00000002.json")
        try FileManager.default.removeItem(at: lockedRevision)
        do {
            _ = try await store.load(sample.job.id)
            XCTFail("deleting the anchored lock tail must fail closed")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
    }

    func testStaleEvidenceCannotLockRenamedSource() async throws {
        let sample = try SampleFactory.balancedModeA()
        let first = sample.job.sources[0]
        let renamed = SourceStatement(
            role: first.role,
            file: SourceFileProof(
                sourceID: first.file.sourceID,
                filename: "renamed-\(first.file.filename)",
                byteCount: first.file.byteCount,
                sha256: first.file.sha256
            ),
            replay: first.replay,
            period: first.period,
            transactions: first.transactions,
            balances: first.balances,
            completeness: first.completeness,
            warnings: first.warnings,
            invalidLocators: first.invalidLocators
        )
        let changedJob = ReconciliationJob(
            id: sample.job.id,
            mode: sample.job.mode,
            period: sample.job.period,
            sources: [renamed, sample.job.sources[1]]
        )
        let changedResult = try ReconciliationEngine().run(changedJob)
        XCTAssertEqual(changedResult, sample.result)
        let evidence = try EvidenceLocker().lock(
            job: sample.job,
            result: sample.result,
            sourceBytesByID: sample.sourceBytesByID,
            lockedAt: "2026-09-22T00:00:00Z"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileEngineStore(root: root, anchorIdentifier: UUID().uuidString, anchorStore: TestAnchorStore())
        let draft = try await store.createDraft(changedJob)
        do {
            _ = try await store.commitLock(
                jobID: changedJob.id,
                expectedRevision: draft.revision,
                result: changedResult,
                evidence: evidence
            )
            XCTFail("evidence from an earlier job version must fail")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
    }
}
