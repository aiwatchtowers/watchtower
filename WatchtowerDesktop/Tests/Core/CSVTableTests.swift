import XCTest
@testable import WatchtowerCore

final class CSVTableTests: XCTestCase {
    func testQuotedFieldsAndEscapedQuotes() {
        XCTAssertEqual(CSVTable.parse("a,b\n1,\"x, y\"\n2,\"he said \"\"hi\"\"\""),
                       [["a", "b"], ["1", "x, y"], ["2", "he said \"hi\""]])
    }

    func testTrailingNewlineAndCRLF() {
        XCTAssertEqual(CSVTable.parse("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTable.parse(""), [])
    }

    func testNewlineInsideQuotes() {
        XCTAssertEqual(CSVTable.parse("h\n\"line1\nline2\""), [["h"], ["line1\nline2"]])
    }
}
