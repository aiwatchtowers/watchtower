import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// `SessionControl`: the Mac-side gates a line, an Esc and a permission
/// answer pass, shared by the phone's handlers and the Workchat composer
/// (#711). No device grants here: those stay the phone's.
@MainActor
final class SessionControlTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var delivery: SessionLineDelivery!
    private var statuses: [Int64: SessionAgentStatus] = [:]
    private var clock: LinkTestClock!
    private var workbenchID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt control \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        statuses = [:]
        clock = LinkTestClock(Date())
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = FakeTerminalSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
        center.transcriptExists = { _ in true }
        delivery = SessionLineDelivery(terminalCenter: center)
        delivery.refreshStates = { true }
        let deliveryClock = try XCTUnwrap(clock)
        delivery.now = { deliveryClock.now }
        delivery.needsApproval = { [weak self] in self?.statuses[$0]?.state.kind == .needsApproval }
        delivery.hasHookState = { _ in true }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    private func makeControl() throws -> SessionControl {
        let clock = try XCTUnwrap(clock)
        return SessionControl(
            dbPool: pool, terminalCenter: center, lineDelivery: delivery,
            status: { [weak self] in self?.statuses[$0] },
            now: { clock.now }
        )
    }

    private func liveSession() async throws -> Int64 {
        let acme = folder.path
        let session = try await pool.write { db -> TerminalSession in
            let project = try TestDatabase.insertWorkbench(db, folder: acme)
            return try TerminalSessionQueries.create(db, .init(
                projectID: project, kind: .claude, title: "Ship it", folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        workbenchID = try XCTUnwrap(session.projectID)
        center.start(session, fresh: true)
        XCTAssertTrue(center.liveIDs.contains(session.id))
        return session.id
    }

    private func setState(
        _ sessionID: Int64, _ kind: SessionSwitcherPresentation.State.Kind, at: String? = "2026-10-12T10:00:00.000Z"
    ) {
        statuses[sessionID] = SessionAgentStatus(
            sessionID: sessionID, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: kind, live: true), at: at
        )
    }

    @discardableResult
    private func request(
        _ sessionID: Int64,
        status: String = "pending",
        tool: String = "Bash",
        summary: String = "make test"
    ) async throws -> Int64 {
        let workbench = workbenchID
        let created = SessionAgentStatus.formatStamp(clock.now.addingTimeInterval(-5))
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests
                        (terminal_session_id, workbench_id, tool_name, summary, summary_clipped, status, created_at)
                    VALUES (?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [sessionID, workbench, tool, summary, status, created]
            )
            return db.lastInsertedRowID
        }
    }

    private func row(_ id: Int64) throws -> Row? {
        try pool.read { try Row.fetchOne($0, sql: "SELECT * FROM permission_requests WHERE id = ?", arguments: [id]) }
    }

    // MARK: - Line check

    func testLineCheckGoWhenIdleAndPromptEmpty() async throws {
        let session = try await liveSession()
        setState(session, .stopped)

        XCTAssertEqual(try makeControl().lineCheck(session), .go)
    }

    func testLineHoldsNeedsApproval() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)

        XCTAssertEqual(try makeControl().lineCheck(session), .hold(.needsApproval))
    }

    func testLineHoldsAgentBusyWhenWorking() async throws {
        let session = try await liveSession()
        setState(session, .working)

        XCTAssertEqual(try makeControl().lineCheck(session), .hold(.agentBusy))
    }

    /// A line submitted 10 s ago, and no hook stamp newer than it: the agent
    /// is turning to it, so the next line waits.
    func testLineHoldsAgentBusyJustAfterSubmit() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        let control = try makeControl()
        let sent = await delivery.deliverLine("First", key: .input("action-1"), sessionID: session) { _ in }
        XCTAssertEqual(sent, .submitted)
        XCTAssertEqual(control.lineCheck(session), .hold(.agentBusy))

        clock.advance(10)
        XCTAssertEqual(control.lineCheck(session), .hold(.agentBusy), "within the settle, no newer hook")

        setState(session, .stopped, at: SessionAgentStatus.formatStamp(clock.now))
        XCTAssertEqual(control.lineCheck(session), .go, "a hook stamp after the submit")
    }

    func testLineHoldsPromptHasText() async throws {
        let session = try await liveSession()
        setState(session, .stopped)
        processes[0].onOwnerInput?(Array("fix the".utf8))

        XCTAssertEqual(try makeControl().lineCheck(session), .hold(.promptHasText))
    }

    func testLineCheckSessionGoneWithoutStatus() async throws {
        let session = try await liveSession()

        XCTAssertEqual(try makeControl().lineCheck(session), .sessionGone)
    }

    // MARK: - Interrupt

    func testInterruptRefusedWithPendingRequest() async throws {
        let session = try await liveSession()
        setState(session, .working)
        try await request(session)

        let result = try await makeControl().interrupt(session)

        XCTAssertEqual(result, .awaitingApproval)
        XCTAssertTrue(typed.isEmpty, "no Esc over a prompt")
    }

    func testInterruptNotWorkingWhenIdle() async throws {
        let session = try await liveSession()
        setState(session, .stopped)

        let result = try await makeControl().interrupt(session)

        XCTAssertEqual(result, .notWorking)
        XCTAssertTrue(typed.isEmpty)
    }

    func testInterruptSends() async throws {
        let session = try await liveSession()
        setState(session, .working)

        let result = try await makeControl().interrupt(session)

        XCTAssertEqual(result, .sent)
        XCTAssertEqual(typed, [[0x1B]])
    }

    // MARK: - Permission

    func testAnswerAllowUpdatesPendingRow() async throws {
        let session = try await liveSession()
        let id = try await request(session)

        let result = try await makeControl().answerPermission(requestID: id, sessionID: session, allow: true, decidedBy: "Mac")

        XCTAssertEqual(result, .applied("allowed"))
        let stored = try XCTUnwrap(row(id))
        XCTAssertEqual(stored["status"] as String, "allowed")
        XCTAssertEqual(stored["decided_by"] as String?, "Mac")
        XCTAssertEqual(stored["decided_at"] as String?, SessionAgentStatus.formatStamp(clock.now))
        XCTAssertTrue(typed.isEmpty, "an answer types nothing")
    }

    /// A path linked into `.claude` reads as a settings path once resolved
    /// (`resolvedSettingsPath`): the Workchat's Allow is refused like the
    /// phone's.
    func testAnswerAllowBlockedForSettingsPath() async throws {
        let session = try await liveSession()
        let settings = folder.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: settings)
        let id = try await request(session, tool: "Edit", summary: link.appendingPathComponent("settings.json").path)

        let result = try await makeControl().answerPermission(requestID: id, sessionID: session, allow: true, decidedBy: "Mac")

        XCTAssertEqual(result, .allowBlocked(.settingsPath))
        XCTAssertEqual(try XCTUnwrap(row(id))["status"] as String, "pending", "left for the Mac's own prompt")
        let denied = try await makeControl().answerPermission(requestID: id, sessionID: session, allow: false, decidedBy: "Mac")
        XCTAssertEqual(denied, .applied("denied"), "a deny always may")
    }

    func testAnswerNotPendingWhenAnsweredMeanwhile() async throws {
        let session = try await liveSession()
        let id = try await request(session, status: "answered_on_mac")

        let result = try await makeControl().answerPermission(requestID: id, sessionID: session, allow: true, decidedBy: "Mac")

        XCTAssertEqual(result, .notPending("answered_on_mac"))
    }

    func testPendingPermissionReturnsNewestPendingRow() async throws {
        let session = try await liveSession()
        try await request(session, summary: "older")
        let newest = try await request(session, summary: "newest")
        try await request(session, status: "denied", summary: "decided")
        let control = try makeControl()

        let prompt = try await control.pendingPermission(session)

        XCTAssertEqual(prompt, SessionControl.PermissionPrompt(id: newest, toolName: "Bash", summary: "newest", allowBlock: nil))
        let none = try await control.pendingPermission(session + 1)
        XCTAssertNil(none, "another session's rows are not its prompt")
    }
}
