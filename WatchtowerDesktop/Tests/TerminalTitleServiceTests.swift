import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Swift side of the `watchtower terminal title` envelope (Go
/// `terminalTitleResult`, cmd/terminal.go — a dual path).
final class TerminalTitleServiceTests: XCTestCase {
    /// An owner's session and one a run of `trigger` started, as the
    /// queries read them (the run's trigger joined).
    private func sessions(trigger: String = "schedule") throws -> (owner: TerminalSession, automation: TerminalSession) {
        let db = try TestDatabase.create()
        return try db.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let automation = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation, trigger: trigger)
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
    /// a poll asks for it; a session a background run (schedule, event, sync,
    /// catch-up) started is background.
    func testOriginFollowsTheSession() async throws {
        let (owner, automation) = try sessions()
        XCTAssertEqual(automation.automationRunTrigger, "schedule", "the queries join the run's trigger")
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"","written":false}"#.utf8))
        _ = try await TerminalTitleService(runner: runner).title(session: owner)
        _ = try await TerminalTitleService(runner: runner).title(session: automation)
        XCTAssertEqual(runner.origins, [.owner, .background])
    }

    /// A run the owner triggered (Run now, a button, a dry run, a reply) is
    /// the owner's gesture: its session's title is owner work too.
    func testAnOwnerTriggeredRunsSessionIsTheOwners() throws {
        for trigger in ["manual", "button", "dry_run", "reply"] {
            XCTAssertEqual(TerminalTitleService.origin(for: try sessions(trigger: trigger).automation), .owner, trigger)
        }
        for trigger in ["schedule", "catch_up", "event", "sync"] {
            XCTAssertEqual(TerminalTitleService.origin(for: try sessions(trigger: trigger).automation), .background, trigger)
        }
    }

    /// BGAI-01: a background run's session is admitted as its run on every
    /// launch (Go `sessionstart.originEnv`'s twin); an owner-run's and the
    /// owner's own carry none.
    func testABackgroundRunsSessionLaunchesAdmitted() throws {
        let (owner, automation) = try sessions()
        let runID = try XCTUnwrap(automation.automationRunID)
        let env = automation.agentOriginEnvironment
        XCTAssertEqual(env, ["WATCHTOWER_AI_ORIGIN=background", "WATCHTOWER_AI_ADMITTED=run:\(runID)"])
        let launch = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newAgent(.claude, sessionID: "s", prompt: nil),
                                         automationRunID: runID, originEnvironment: env)
        XCTAssertTrue(Set(env).isSubset(of: Set(launch.environment)))
        XCTAssertTrue(owner.agentOriginEnvironment.isEmpty)
        XCTAssertTrue(try sessions(trigger: "manual").automation.agentOriginEnvironment.isEmpty)
    }

    /// #1886 (F4): a title the CLI refused because background AI is paused
    /// ran no model, so it does not use the session's attempt budget up.
    func testAPausedRefusalIsNotATitleAttempt() {
        let paused = CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: Background AI is paused\n")
        XCTAssertTrue(paused.isBackgroundAIPaused)
        XCTAssertFalse(WorkbenchesViewModel.countsAsTitleAttempt(paused))
        XCTAssertTrue(WorkbenchesViewModel.countsAsTitleAttempt(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")))
        XCTAssertTrue(WorkbenchesViewModel.countsAsTitleAttempt(CLIRunnerError.binaryNotFound))
    }
}
