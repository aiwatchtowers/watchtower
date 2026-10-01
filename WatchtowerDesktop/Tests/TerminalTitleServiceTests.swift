import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The Swift side of the `watchtower terminal title` envelope (Go
/// `terminalTitleResult`, cmd/terminal.go — a dual path).
final class TerminalTitleServiceTests: XCTestCase {
    func testRunsTheTitleCommandAndDecodesItsEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"Fix the login redirect","written":true}"#.utf8))
        let result = try await TerminalTitleService(runner: runner).title(sessionID: 42)

        XCTAssertEqual(runner.invocations, [["terminal", "title", "42", "--json"]])
        XCTAssertEqual(result, TerminalTitleResult(title: "Fix the login redirect", written: true))
    }

    func testDecodesTheNotWrittenEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"","written":false}"#.utf8))
        let result = try await TerminalTitleService(runner: runner).title(sessionID: 7)

        XCTAssertEqual(result, TerminalTitleResult(title: "", written: false))
    }
}
