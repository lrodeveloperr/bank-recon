import Foundation
import XCTest
@testable import BankReconciliationEngine

final class DelimitedParserTests: XCTestCase {
    private func context() throws -> (ReconciliationPeriod, DelimitedMapping) {
        let period = try ReconciliationPeriod(start: LocalDate(iso8601: "2026-01-01"), end: LocalDate(iso8601: "2026-01-31"))
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true,
            dateColumn: 0, amountColumn: 1, accountColumn: 2, currencyColumn: 3,
            strongIDColumn: 4, dateOrder: .ymd, decimalSeparator: "."
        )
        return (period, mapping)
    }

    func testStrictQuotesAndWidth() throws {
        let (period, mapping) = try context()
        let parser = DelimitedParser()
        XCTAssertThrowsError(try parser.parse(
            data: Data("date,amount,account,currency,id\n2026-01-01,1,A,USD,\"x\"junk\n".utf8),
            filename: "bad.csv", role: .bank, period: period, mapping: mapping, format: .csv
        ))
        XCTAssertThrowsError(try parser.parse(
            data: Data("date,amount,account,currency,id\n2026-01-01,1,A,USD\n".utf8),
            filename: "bad.csv", role: .bank, period: period, mapping: mapping, format: .csv
        ))
    }

    func testSelectedMappingIsReplayable() throws {
        let (period, mapping) = try context()
        let data = Data("date,amount,account,currency,id\n2026-01-01,1.20,A,USD,X1\n".utf8)
        let source = try DelimitedParser().parse(data: data, filename: "ok.csv", role: .bank, period: period, mapping: mapping, format: .csv)
        XCTAssertEqual(source.replay.delimitedMapping, mapping)
        XCTAssertEqual(source.transactions[0].amount.description, "1.2")
        XCTAssertEqual(source.transactions[0].originalValues.count, 5)
        XCTAssertEqual(source.transactions[0].originalValues["column:4"], "X1")
    }

    func testCRLFAndCRRecordsRemainDistinct() throws {
        let (period, mapping) = try context()
        let parser = DelimitedParser()
        for newline in ["\r\n", "\r"] {
            let text = "date,amount,account,currency,id\(newline)2026-01-01,1,A,USD,X1\(newline)"
            let source = try parser.parse(
                data: Data(text.utf8), filename: "windows.csv", role: .bank,
                period: period, mapping: mapping, format: .csv
            )
            XCTAssertEqual(source.transactions.count, 1)
            XCTAssertEqual(source.transactions[0].locator, "line:2")
        }
    }

    func testQuotedCRLFTracksFollowingPhysicalLine() throws {
        let period = try ReconciliationPeriod(start: LocalDate(iso8601: "2026-01-01"), end: LocalDate(iso8601: "2026-01-31"))
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true,
            dateColumn: 0, amountColumn: 1, accountColumn: 2, currencyColumn: 3,
            strongIDColumn: 4, descriptionColumn: 5,
            dateOrder: .ymd, decimalSeparator: "."
        )
        let data = Data("date,amount,account,currency,id,description\r\n2026-01-01,1,A,USD,X1,\"first\r\nsecond\"\r\n2026-01-02,2,A,USD,X2,last\r\n".utf8)
        let source = try DelimitedParser().parse(
            data: data, filename: "multiline.csv", role: .bank,
            period: period, mapping: mapping, format: .csv
        )
        XCTAssertEqual(source.transactions.count, 2)
        XCTAssertEqual(source.transactions[1].locator, "line:4")
    }
}
