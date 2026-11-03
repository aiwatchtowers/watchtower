import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The app's side of the Go hub's Desktop events (go hub plan 3 Task 24):
/// PROJ-16's typing notice and a phone start's "Bring the window forward".
@MainActor
final class HubDesktopEventsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var appState: AppState!

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        appState = AppState { [:] }
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
    }

    override func tearDown() async throws {
        appState.sessionAgentStateCenter?.stop()
        appState.sessionReportCenter?.stop()
        appState.workbenchNotificationCenter?.stop()
        appState.workbenchesViewModel?.asks.stop()
        appState.stopHubCenterForQuit()
        appState = nil
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    /// OD-2: the notice asks only while the app is in the background; in
    /// front, the request shows on the phone's row in Settings → Mobile.
    func testTheTypingNoticeIsPostedOnlyWhileTheAppIsInactive() {
        var active = true
        var posted: [String] = []
        appState.appIsActive = { active }
        appState.postTypingRequestNotice = { posted.append("\($0) \($1)") }

        appState.hubTypingRequested(deviceID: "AABB", name: "Colleague A's iPhone")
        XCTAssertEqual(posted, [], "the app is in front: no notice")

        active = false
        appState.hubTypingRequested(deviceID: "AABB", name: "Colleague A's iPhone")
        XCTAssertEqual(posted, ["AABB Colleague A's iPhone"])
    }

    /// Spec §6.5: the workbench comes forward on the main window and the
    /// session the hub started is shown as Work on it shows one — the board
    /// kept beside it. Nothing is started on the Mac.
    func testBringForwardShowsTheWorkbenchAndTheSessionWithTheBoardKept() async throws {
        appState.initWorkbenches(
            dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        let (other, project, session) = try await pool.write { db -> (Int64, Int64, Int64) in
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            let project = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            try db.execute(
                sql: """
                    INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
                    VALUES (?, 'claude', 'From the phone', '/tmp/acme', '00000000-0000-4000-8000-000000000001')
                    """,
                arguments: [project]
            )
            return (other, project, db.lastInsertedRowID)
        }
        await vm.reload()
        vm.selectedWorkbenchID = other
        var fronted = 0
        appState.frontMainWindow = { _ in fronted += 1 }

        await appState.bringWorkbenchForward(projectID: project, sessionID: session)

        XCTAssertEqual(appState.selectedDestination, .workbench)
        XCTAssertEqual(vm.selectedWorkbenchID, project, "the phone's workbench, not the one on screen")
        XCTAssertEqual(fronted, 1, "the main window comes forward once")
        XCTAssertEqual(vm.layout(projectID: project).primary, .session(session), "a single pane switches to the session")
        XCTAssertFalse(appState.terminalCenter.liveIDs.contains(session), "nothing is started on the Mac")

        // Split with the board, it stays: the session takes the other pane.
        var split = WatchtowerCore.WorkspaceLayout.default
        split.split(with: .files)
        XCTAssertEqual(split.visiblePanes, [.board, .files])
        vm.setLayout(split, projectID: project)
        await appState.bringWorkbenchForward(projectID: project, sessionID: session)
        let kept = vm.layout(projectID: project)
        XCTAssertTrue(kept.visiblePanes.contains(.board), "Work on it keeps the board")
        XCTAssertTrue(kept.showsSession(session))
        XCTAssertFalse(kept.visiblePanes.contains(.files), "the other pane gives way")
    }
}
