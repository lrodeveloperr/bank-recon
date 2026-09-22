import Foundation

public enum SampleFactory {
    public struct SampleBundle: Sendable {
        public let job: ReconciliationJob
        public let result: ReconciliationResult
        public let sourceBytesByID: [String: Data]

        public init(job: ReconciliationJob, result: ReconciliationResult, sourceBytesByID: [String: Data]) {
            self.job = job
            self.result = result
            self.sourceBytesByID = sourceBytesByID
        }
    }

    public static func balancedModeA() throws -> SampleBundle {
        let period = try ReconciliationPeriod(start: LocalDate(iso8601: "2026-01-01"), end: LocalDate(iso8601: "2026-01-31"))
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true,
            dateColumn: 0, amountColumn: 1, accountColumn: 2, currencyColumn: 3,
            strongIDColumn: 4, referenceColumn: 5, descriptionColumn: 6, runningBalanceColumn: 7,
            dateOrder: .ymd, decimalSeparator: "."
        )
        let bankData = Data("date,amount,account,currency,id,reference,description,balance\n2026-01-02,125.50,CHK-01,USD,T-001,INV-44,Payment,125.50\n2026-01-05,-25.50,CHK-01,USD,T-002,FEE-1,Fee,100.00\n".utf8)
        let ledgerData = Data("date,amount,account,currency,id,reference,description,balance\n2026-01-02,125.50,CHK-01,USD,T-001,INV-44,Payment,125.50\n2026-01-05,-25.50,CHK-01,USD,T-002,FEE-1,Fee,100.00\n\n".utf8)
        let parser = DelimitedParser()
        let bank = try parser.parse(data: bankData, filename: "bank.csv", role: .bank, period: period, mapping: mapping, format: .csv)
        let ledger = try parser.parse(data: ledgerData, filename: "ledger.csv", role: .ledger, period: period, mapping: mapping, format: .csv)
        guard let sampleID = UUID(uuidString: "1C6D71A7-8F44-4E54-8F06-070042A40411") else {
            throw EngineError.integrityFailure("invalid built-in sample identifier")
        }
        let job = ReconciliationJob(
            id: sampleID,
            mode: .bankVsLedger,
            period: period,
            sources: [bank, ledger]
        )
        let result = try ReconciliationEngine().run(job)
        return SampleBundle(
            job: job,
            result: result,
            sourceBytesByID: [bank.file.sourceID: bankData, ledger.file.sourceID: ledgerData]
        )
    }
}
