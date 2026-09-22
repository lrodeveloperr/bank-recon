import BankReconciliationEngine
import Foundation

@main
enum BankReconciliationCLI {
    static func main() throws {
        guard CommandLine.arguments.dropFirst().first == "verify-fixtures" else {
            print("usage: bank-reconcile verify-fixtures")
            return
        }
        let sample = try SampleFactory.balancedModeA()
        guard sample.result.state == .reconciled,
              sample.result.matches.count == 2,
              sample.result.exceptions.isEmpty else {
            throw EngineError.integrityFailure("built-in sample did not reconcile")
        }
        let evidence = try EvidenceLocker().lock(
            job: sample.job,
            result: sample.result,
            sourceBytesByID: sample.sourceBytesByID,
            lockedAt: "2026-09-22T00:00:00Z"
        )
        try EvidenceLocker().verify(evidence)
        print("PASS \(evidence.evidenceID) \(evidence.manifestSHA256)")
    }
}
