import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Swift side of the `watchtower terminal title` envelope (Go
/// `terminalTitleResult`, cmd/terminal.go — a dual path).
final class TerminalTitleServiceTests: XCTestCase {
    /// An owner's session and, with `run`, one an automation run started.
    private func sessions() throws -> (owner: TerminalSession, automation: TerminalSession) {
        let db = try TestDatabase.create()
        return try db.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let automation = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            let owner = try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .claude, title: "a", folderPath: "/tmp/acme", claudeSessionID: "s-1"))
            let started = try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .claude, title: "b", folderPath: "/tmp/acme", claudeSessionID: "s-2",
                automationRunID: run))
            return (owner, started)
        }
    }

    func testRunsTheTitleCommandAndDecodesItsEnvelope() async throws {
        let session = try sessions().owner
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"Fix the login redirect","written":true}"#.utf8))
        let result = try await TerminalTitleService(runner: runner).title(session: session)

        XCTAssertEqual(runner.invocations, [["terminal", "title", String(session.id), "--json"]])
        XCTAssertEqual(result, TerminalTitleResult(title: "Fix the login redirect", written: true))
    }

    func testDecodesTheNotWrittenEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"","written":false}"#.utf8))
        let result = try await TerminalTitleService(runner: runner).title(session: try sessions().owner)

        XCTAssertEqual(result, TerminalTitleResult(title: "", written: false))
    }

    /// Spec §2.2: a title of the owner's own session is owner work even though
    /// a poll asks for it; a session an automation run started is background.
    func testOriginFollowsTheSession() async throws {
        let (owner, automation) = try sessions()
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"","written":false}"#.utf8))
        _ = try await TerminalTitleService(runner: runner).title(session: owner)
        _ = try await TerminalTitleService(runner: runner).title(session: automation)
        XCTAssertEqual(runner.origins, [.owner, .background])
    }
}
