import XCTest
@testable import WatchtowerCore

/// `watchtower diagnostics --json` answer. The keys are pinned on the Go
/// side by `TestReport_JSONKeys` (internal/diagnostics).
final class DiagnosticsAnswerTests: XCTestCase {
    private let json = """
    {"text":"Watchtower 0.30.0 (commit abc1234, flavor: default) · app 0.30.0\\nmacOS 15.5 · Apple M3",\
    "version":"0.30.0","macos":"macOS 15.5","chip":"Apple M3","provider":"Claude Code",\
    "sources":["Slack","Jira"],"flavor":"default","partial":false}
    """

    func testDecodesPinnedKeys() throws {
        let answer = try DiagnosticsAnswer.decode(stdout: Data(json.utf8))
        XCTAssertEqual(answer, DiagnosticsAnswer(
            text: "Watchtower 0.30.0 (commit abc1234, flavor: default) · app 0.30.0\nmacOS 15.5 · Apple M3",
            version: "0.30.0",
            macos: "macOS 15.5",
            chip: "Apple M3",
            provider: "Claude Code",
            flavor: "default",
            sources: ["Slack", "Jira"],
            partial: false
        ))
    }

    func testDecodesLastJSONLine() throws {
        let stdout = "warning: x\n" + json + "\n\n"
        let answer = try DiagnosticsAnswer.decode(stdout: Data(stdout.utf8))
        XCTAssertEqual(answer.version, "0.30.0")
        XCTAssertEqual(answer.sources, ["Slack", "Jira"])
    }

    func testMissingKeyFails() {
        let noPartial = json.replacingOccurrences(of: ",\"partial\":false", with: "")
        XCTAssertNotEqual(noPartial, json)
        XCTAssertThrowsError(try DiagnosticsAnswer.decode(stdout: Data(noPartial.utf8)))
    }

    func testEmptyOutputFails() {
        XCTAssertThrowsError(try DiagnosticsAnswer.decode(stdout: Data("\n \n".utf8)))
        XCTAssertThrowsError(try DiagnosticsAnswer.decode(stdout: Data()))
    }
}
