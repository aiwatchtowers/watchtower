import XCTest
@testable import WatchtowerCore

final class CodeFileNameTests: XCTestCase {
    func testANameOrAPathUnderTheDirectory() throws {
        XCTAssertEqual(try CodeFileName.resolve("main.go", in: ""), "main.go")
        XCTAssertEqual(try CodeFileName.resolve("  foo/bar.go ", in: "internal"), "internal/foo/bar.go")
        XCTAssertEqual(try CodeFileName.resolve(".env.local", in: "cmd"), "cmd/.env.local")
    }

    func testRefusesWhatWouldLeaveTheFolderOrIsEmpty() {
        XCTAssertThrowsError(try CodeFileName.resolve("   ", in: "")) { XCTAssertEqual($0 as? CodeFileName.Problem, .empty) }
        XCTAssertThrowsError(try CodeFileName.resolve("/etc/hosts", in: "")) { XCTAssertEqual($0 as? CodeFileName.Problem, .absolute) }
        XCTAssertThrowsError(try CodeFileName.resolve("~/x", in: "")) { XCTAssertEqual($0 as? CodeFileName.Problem, .absolute) }
        XCTAssertThrowsError(try CodeFileName.resolve("../x", in: "a")) {
            XCTAssertEqual($0 as? CodeFileName.Problem, .badComponent(".."))
        }
        XCTAssertThrowsError(try CodeFileName.resolve("a//b", in: "")) {
            XCTAssertEqual($0 as? CodeFileName.Problem, .badComponent("//"))
        }
        XCTAssertThrowsError(try CodeFileName.resolve("a/./b", in: ""))
    }
}
