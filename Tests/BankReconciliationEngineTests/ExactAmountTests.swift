import XCTest
@testable import BankReconciliationEngine

final class ExactAmountTests: XCTestCase {
    func testLocalizedParsingAndCheckedArithmetic() throws {
        let left = try ExactAmount(parsing: "1.234,50", decimalSeparator: ",", groupingSeparator: ".")
        let right = try ExactAmount(parsing: "-34,5", decimalSeparator: ",")
        XCTAssertEqual(try left.adding(right).description, "1200")
        XCTAssertThrowsError(try ExactAmount(parsing: "1e9"))
        XCTAssertThrowsError(try ExactAmount(parsing: "0.1234567"))
    }

    func testExactDateRejectsPrefixAndInvalidDay() {
        XCTAssertThrowsError(try LocalDate(iso8601: "2026-01-01T00:00:00Z"))
        XCTAssertThrowsError(try LocalDate(iso8601: "2026-02-30"))
        XCTAssertThrowsError(try LocalDate(iso8601: "ééééé"))
    }

    func testMinimumIntegerCanSubtractItself() throws {
        let minimum = try ExactAmount(parsing: "-9223372036854775808")
        XCTAssertEqual(try minimum.subtracting(minimum), .zero)
    }
}
