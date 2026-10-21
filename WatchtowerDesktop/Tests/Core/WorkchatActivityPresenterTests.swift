import XCTest
@testable import WatchtowerCore

final class WorkchatActivityPresenterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func activity(_ tool: String = "Bash", more: Int = 0) -> SessionFeedActivity {
        SessionFeedActivity(tool: tool, summary: "go test ./...", startedAt: t0, more: more)
    }

    private func line(
        _ activity: SessionFeedActivity?,
        working: Bool = true,
        background: Bool = false,
        subagents: Int = 0,
        lastAgentAt: Date? = nil
    ) -> WorkchatActivityPresenter.Line? {
        WorkchatActivityPresenter.line(
            activity: activity, working: working, background: background, runningSubagents: subagents,
            stateAt: t0 - 5, lastAgentAt: lastAgentAt)
    }

    func testBashLine() {
        XCTAssertEqual(line(activity()), .init(symbol: "terminal", text: "go test ./...", since: t0))
    }

    func testMoreSuffix() {
        XCTAssertEqual(line(activity(more: 2))?.text, "go test ./... · 2 more")
    }

    func testThinkingWhenNoActivity() {
        XCTAssertEqual(line(nil), .init(symbol: "ellipsis", text: "Thinking…", since: t0 - 5))
    }

    func testBackgroundAgentsCount() {
        XCTAssertEqual(line(nil, background: true, subagents: 3), .init(symbol: "person.2", text: "Agents working · 3", since: t0 - 5))
        XCTAssertEqual(line(nil, background: true)?.text, "Agents working")
    }

    func testHiddenWhenNotWorkingEvenWithOpenTool() {
        XCTAssertNil(line(activity(), working: false))
    }

    func testHiddenAfterNewerAgentText() {
        XCTAssertEqual(line(activity(), lastAgentAt: t0 + 1)?.text, "Thinking…")
        XCTAssertEqual(line(activity(), lastAgentAt: t0 - 1)?.symbol, "terminal")
    }

    func testSymbols() {
        XCTAssertEqual(WorkchatActivityPresenter.symbol(for: "Edit"), "pencil")
        XCTAssertEqual(WorkchatActivityPresenter.symbol(for: "mcp__x__y"), "powerplug")
        XCTAssertEqual(WorkchatActivityPresenter.symbol(for: "exec"), "gearshape")
    }
}
