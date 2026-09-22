import Foundation
import XCTest
@testable import BankReconciliationEngine

final class ReconciliationTests: XCTestCase {
    func testBalancedSampleAndEvidenceReplay() throws {
        let sample = try SampleFactory.balancedModeA()
        XCTAssertEqual(sample.result.state, .reconciled)
        XCTAssertEqual(sample.result.matches.count, 2)
        let evidence = try EvidenceLocker().lock(
            job: sample.job,
            result: sample.result,
            sourceBytesByID: sample.sourceBytesByID,
            lockedAt: "2026-09-22T00:00:00Z"
        )
        try EvidenceLocker().verify(evidence)
        XCTAssertFalse(evidence.canonicalManifest.isEmpty)
        XCTAssertEqual(evidence.sourceBlobs.count, 2)
    }

    func testEvidenceRejectsChangedBytes() throws {
        let sample = try SampleFactory.balancedModeA()
        let changed = Dictionary(uniqueKeysWithValues: sample.sourceBytesByID.map { entry -> (String, Data) in
            var data = entry.value
            data.append(0x20)
            return (entry.key, data)
        })
        XCTAssertThrowsError(try EvidenceLocker().lock(
            job: sample.job,
            result: sample.result,
            sourceBytesByID: changed,
            lockedAt: "2026-09-22T00:00:00Z"
        ))
    }

    func testModeRolesFailClosed() throws {
        let sample = try SampleFactory.balancedModeA()
        let invalid = ReconciliationJob(mode: .singleStatement, period: sample.job.period, sources: sample.job.sources)
        XCTAssertThrowsError(try ReconciliationEngine().run(invalid))
    }

    func testBalanceOnlyStatementCanReconcile() throws {
        let date = try LocalDate(iso8601: "2026-01-31")
        let period = try ReconciliationPeriod(start: LocalDate(iso8601: "2026-01-01"), end: date)
        let currency = try CurrencyCode("USD")
        let amount = try ExactAmount(parsing: "100.00")
        let balances = [
            StatementBalance(kind: .opening, account: "A", currency: currency, date: try LocalDate(iso8601: "2026-01-01"), amount: amount, locator: "opening"),
            StatementBalance(kind: .closing, account: "A", currency: currency, date: date, amount: amount, locator: "closing")
        ]
        let source = SourceStatement(
            role: .statement,
            file: SourceFileProof(sourceID: "test", filename: "statement.csv", byteCount: 0, sha256: Hashing.sha256(Data())),
            replay: ParseReplayDescriptor(format: .csv, parserVersion: DelimitedParser.version, balanceOverrides: balances),
            period: period,
            transactions: [],
            balances: balances
        )
        let result = try ReconciliationEngine().run(ReconciliationJob(mode: .singleStatement, period: period, sources: [source]))
        XCTAssertEqual(result.state, .reconciled)
        XCTAssertTrue(result.exceptions.isEmpty)
    }

    func testDuplicateLocatorFailsWithoutDictionaryTrap() throws {
        let sample = try SampleFactory.balancedModeA()
        let bank = sample.job.sources[0]
        let duplicated = SourceStatement(
            role: bank.role,
            file: bank.file,
            replay: bank.replay,
            period: bank.period,
            transactions: bank.transactions + [bank.transactions[0]],
            balances: bank.balances,
            completeness: bank.completeness,
            warnings: bank.warnings,
            invalidLocators: bank.invalidLocators
        )
        let job = ReconciliationJob(mode: .bankVsLedger, period: sample.job.period, sources: [duplicated, sample.job.sources[1]])
        XCTAssertThrowsError(try ReconciliationEngine().run(job))
    }

    func testRunningBalanceGapCarriesInterveningActivity() throws {
        let start = try LocalDate(iso8601: "2026-01-01")
        let end = try LocalDate(iso8601: "2026-01-31")
        let period = try ReconciliationPeriod(start: start, end: end)
        let currency = try CurrencyCode("USD")
        let transactions = [
            CanonicalTransaction(sourceID: "s", locator: "1", sourceOrdinal: 0, account: "A", currency: currency, bookingDate: start, amount: try ExactAmount(parsing: "10"), runningBalance: try ExactAmount(parsing: "110")),
            CanonicalTransaction(sourceID: "s", locator: "2", sourceOrdinal: 1, account: "A", currency: currency, bookingDate: start, amount: try ExactAmount(parsing: "5")),
            CanonicalTransaction(sourceID: "s", locator: "3", sourceOrdinal: 2, account: "A", currency: currency, bookingDate: start, amount: try ExactAmount(parsing: "2"), runningBalance: try ExactAmount(parsing: "999"))
        ]
        let balances = [
            StatementBalance(kind: .opening, account: "A", currency: currency, date: start, amount: try ExactAmount(parsing: "100"), locator: "open"),
            StatementBalance(kind: .closing, account: "A", currency: currency, date: end, amount: try ExactAmount(parsing: "117"), locator: "close")
        ]
        let source = SourceStatement(
            role: .statement,
            file: SourceFileProof(sourceID: "s", filename: "gap.csv", byteCount: 0, sha256: Hashing.sha256(Data())),
            replay: ParseReplayDescriptor(format: .csv, parserVersion: DelimitedParser.version, balanceOverrides: balances),
            period: period,
            transactions: transactions,
            balances: balances
        )
        let result = try ReconciliationEngine().run(ReconciliationJob(mode: .singleStatement, period: period, sources: [source]))
        XCTAssertTrue(result.exceptions.contains { $0.kind == .runningBalanceBreak })
        XCTAssertEqual(result.state, .differenceFound)
    }

    func testStrongIdentifierMatchingIsCaseSensitive() throws {
        let date = try LocalDate(iso8601: "2026-01-01")
        let period = try ReconciliationPeriod(start: date, end: date)
        let currency = try CurrencyCode("USD")
        func source(role: SourceRole, sourceID: String, strongID: String) throws -> SourceStatement {
            SourceStatement(
                role: role,
                file: SourceFileProof(sourceID: sourceID, filename: "\(sourceID).csv", byteCount: 0, sha256: Hashing.sha256(Data())),
                replay: ParseReplayDescriptor(format: .csv, parserVersion: DelimitedParser.version),
                period: period,
                transactions: [CanonicalTransaction(
                    sourceID: sourceID, locator: "line:1", account: "A", currency: currency,
                    bookingDate: date, amount: try ExactAmount(parsing: "1"), strongID: strongID
                )]
            )
        }
        let bank = try source(role: .bank, sourceID: "bank", strongID: "ABC")
        let ledger = try source(role: .ledger, sourceID: "ledger", strongID: "abc")
        let result = try ReconciliationEngine().run(ReconciliationJob(mode: .bankVsLedger, period: period, sources: [bank, ledger]))
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.state, .differenceFound)
    }

    func testStructuredMatchKeysCannotCrossAccountBoundaries() throws {
        let period = try ReconciliationPeriod(start: LocalDate(iso8601: "2026-01-01"), end: LocalDate(iso8601: "2026-01-31"))
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true,
            dateColumn: 0, amountColumn: 1, accountColumn: 2, currencyColumn: 3,
            strongIDColumn: 4, dateOrder: .ymd, decimalSeparator: "."
        )
        let leftData = Data("date,amount,account,currency,id\n2026-01-01,1,A|USD,USD,X\n".utf8)
        let rightData = Data("date,amount,account,currency,id\n2026-01-01,1,A,USD,USD|X\n".utf8)
        let parser = DelimitedParser()
        let left = try parser.parse(data: leftData, filename: "bank.csv", role: .bank, period: period, mapping: mapping, format: .csv)
        let right = try parser.parse(data: rightData, filename: "ledger.csv", role: .ledger, period: period, mapping: mapping, format: .csv)
        let result = try ReconciliationEngine().run(ReconciliationJob(mode: .bankVsLedger, period: period, sources: [left, right]))
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.state, .differenceFound)
    }

    func testDelimitedModeCParsesLocksAndReplaysBalanceOverrides() throws {
        let start = try LocalDate(iso8601: "2026-01-01")
        let end = try LocalDate(iso8601: "2026-01-31")
        let period = try ReconciliationPeriod(start: start, end: end)
        let currency = try CurrencyCode("USD")
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true,
            dateColumn: 0, amountColumn: 1, accountColumn: 2, currencyColumn: 3,
            strongIDColumn: 4, dateOrder: .ymd, decimalSeparator: "."
        )
        let replay = ParseReplayDescriptor(
            format: .csv,
            parserVersion: DelimitedParser.version,
            delimitedMapping: mapping,
            balanceOverrides: [
                StatementBalance(kind: .opening, account: "A", currency: currency, date: start, amount: try ExactAmount(parsing: "100"), locator: "user:opening"),
                StatementBalance(kind: .closing, account: "A", currency: currency, date: end, amount: try ExactAmount(parsing: "105"), locator: "user:closing")
            ]
        )
        let data = Data("date,amount,account,currency,id\r\n2026-01-10,5,A,USD,X1\r\n".utf8)
        let source = try FormatRouter().parse(
            data: data, filename: "statement.csv", role: .statement,
            period: period, replay: replay
        )
        let job = ReconciliationJob(mode: .singleStatement, period: period, sources: [source])
        let result = try ReconciliationEngine().run(job)
        XCTAssertEqual(result.state, .reconciled)
        XCTAssertEqual(result.totals.count, 1)
        XCTAssertEqual(result.totals[0].kind, .statementBalanceEquation)
        XCTAssertEqual(result.totals[0].left.description, "105")
        XCTAssertEqual(result.totals[0].right.description, "105")
        XCTAssertEqual(result.totals[0].difference, .zero)
        let evidence = try EvidenceLocker().lock(
            job: job,
            result: result,
            sourceBytesByID: [source.file.sourceID: data],
            lockedAt: "2026-09-22T00:00:00Z"
        )
        try EvidenceLocker().verify(evidence, job: job, result: result)
    }
}
