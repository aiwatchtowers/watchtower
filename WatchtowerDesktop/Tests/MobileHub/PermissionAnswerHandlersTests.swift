import AppKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// A process that records every byte written into it.
@MainActor
private final class ByteProbeSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var onOwnerInput: (([UInt8]) -> Void)?
    var bracketedPasteMode = true
    private(set) var inputs: [[UInt8]] = []

    func start(_ launch: TerminalLaunch) {}
    func detach() {}
    func sendInput(_ bytes: [UInt8]) { inputs.append(bytes) }
}

/// `permission_answer` and `session_interrupt` from the phone (#517, spec
/// 2026-10-17-phone-permission-answers §5.3, §6): an answer decides a
/// pending row once, from a device with its own grant, and types nothing;
/// an interrupt is one Esc, only while the agent works and only while the
/// action is fresh.
@MainActor
final class PermissionAnswerHandlersTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var folder: URL!
    private var processes: [ByteProbeSession] = []
    private var center: TerminalCenter!
    private var sidecar: HubSyncState!
    private var statuses: [Int64: SessionAgentStatus] = [:]
    private var clock: LinkTestClock!
    private var workbenchID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt permission \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        statuses = [:]
        clock = LinkTestClock(Date())
        center = TerminalCenter(
            makeProcess: { [weak self] in
                let process = ByteProbeSession()
                self?.processes.append(process)
                return process
            },
            signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in })
        )
        center.shell = { "/bin/zsh" }
        center.copyToClipboard = { _ in }
        center.transcriptExists = { _ in true }
        sidecar = try HubSyncState.inMemory()
        try sidecar.linkTestDevice(testPhoneID)
        _ = try sidecar.setDeviceGrant(.permissions, true, deviceID: testPhoneID, at: Date())
        _ = try sidecar.setDeviceGrant(.typing, true, deviceID: testPhoneID, at: Date())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var typed: [[UInt8]] { processes.flatMap(\.inputs) }

    private func makeHandlers() throws -> PermissionAnswerHandlers {
        let clock = try XCTUnwrap(clock)
        let sidecar = try XCTUnwrap(sidecar)
        return PermissionAnswerHandlers(
            dbPool: pool, terminalCenter: center,
            status: { [weak self] in self?.statuses[$0] },
            deviceGrant: { MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
            deviceName: { MobileLinkCenter.deviceName(sidecar, deviceID: $0) },
            now: { clock.now }
        )
    }

    /// A running `claude` session on the test workbench (made by the first
    /// call).
    private func liveSession() async throws -> Int64 {
        let acme = folder.path
        let existing = workbenchID
        let session = try await pool.write { db -> TerminalSession in
            let project = existing != 0 ? existing : try TestDatabase.insertWorkbench(db, folder: acme)
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

    private func setState(_ sessionID: Int64, _ kind: SessionSwitcherPresentation.State.Kind) {
        statuses[sessionID] = SessionAgentStatus(
            sessionID: sessionID, workbenchID: workbenchID, workbenchName: "acme", title: "Ship it",
            state: .init(kind: kind, live: true), at: "2026-10-17T10:00:00.000Z"
        )
    }

    private func request(_ sessionID: Int64, status: String = "pending") async throws -> Int64 {
        let workbench = workbenchID
        let created = SessionAgentStatus.formatStamp(clock.now.addingTimeInterval(-5))
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
                    VALUES (?, ?, 'Bash', 'make test', ?, ?)
                    """,
                arguments: [sessionID, workbench, status, created]
            )
            return db.lastInsertedRowID
        }
    }

    private func row(_ id: Int64) throws -> Row? {
        try pool.read { try Row.fetchOne($0, sql: "SELECT * FROM permission_requests WHERE id = ?", arguments: [id]) }
    }

    private func answer(
        _ sessionID: Int64, request: Int64, _ behavior: String = "allow", device: String = testPhoneID
    ) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .permissionAnswer, entityID: String(sessionID),
            params: ["request_id": .integer(request), "behavior": .string(behavior)],
            createdAt: clock.now, deviceID: device
        )
    }

    private func interrupt(_ sessionID: Int64, age: TimeInterval = 1) -> ActionRequestPayload {
        ActionRequestPayload(
            id: UUID().uuidString, kind: .sessionInterrupt, entityID: String(sessionID), params: [:],
            createdAt: clock.now.addingTimeInterval(-age), deviceID: testPhoneID
        )
    }

    // MARK: - Answer

    func testProj21_AnUngrantedDeviceCannotAnswer() async throws {
        let session = try await liveSession()
        let id = try await request(session)
        _ = try sidecar.setDeviceGrant(.permissions, false, deviceID: testPhoneID, at: Date())

        let outcome = try await makeHandlers().handle(answer(session, request: id))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .deviceNotAllowed)
        XCTAssertEqual(try row(id)?["status"], "pending")
        XCTAssertNil(try row(id)?["decided_by"] as String?)
    }

    /// The typing grant does not imply the permission grant.
    func testTheTypingGrantAloneCannotAnswer() async throws {
        let session = try await liveSession()
        let id = try await request(session)
        _ = try sidecar.setDeviceGrant(.permissions, false, deviceID: testPhoneID, at: Date())
        XCTAssertTrue(MobileLinkCenter.sessionGrant(sidecar, deviceID: testPhoneID).typingAllowed)

        let outcome = try await makeHandlers().handle(answer(session, request: id))

        XCTAssertEqual(outcome.reason, .deviceNotAllowed)
        XCTAssertEqual(try row(id)?["status"], "pending")
    }

    func testProj21_AnAllowDecidesThePendingRowOnce() async throws {
        let session = try await liveSession()
        let id = try await request(session)
        let handlers = try makeHandlers()

        let first = try await handlers.handle(answer(session, request: id))
        let second = try await handlers.handle(answer(session, request: id, "deny"))

        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(first.result?["status"], .string("allowed"))
        XCTAssertEqual(second.status, .failed)
        XCTAssertEqual(second.reason, .notPending)
        let decided = try XCTUnwrap(try row(id))
        XCTAssertEqual(decided["status"], "allowed")
        XCTAssertEqual(decided["decided_by"], "iPhone")
        XCTAssertEqual(decided["decided_at"], SessionAgentStatus.formatStamp(clock.now))
    }

    func testADenyDecidesThePendingRow() async throws {
        let session = try await liveSession()
        let id = try await request(session)

        let outcome = try await makeHandlers().handle(answer(session, request: id, "deny"))

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(try row(id)?["status"], "denied")
    }

    func testAnAnswerAfterTheMacAnsweredIsNotPending() async throws {
        let session = try await liveSession()
        let id = try await request(session, status: "answered_on_mac")

        let outcome = try await makeHandlers().handle(answer(session, request: id))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .notPending)
        XCTAssertEqual(outcome.errorMessage, "Answered on the Mac")
        XCTAssertEqual(try row(id)?["status"], "answered_on_mac")
    }

    func testAnAnswerToAnExpiredRequestIsNotPending() async throws {
        let session = try await liveSession()
        let id = try await request(session, status: "expired")

        let outcome = try await makeHandlers().handle(answer(session, request: id))

        XCTAssertEqual(outcome.reason, .notPending)
        XCTAssertEqual(outcome.errorMessage, "Too late — answer on the Mac")
        XCTAssertEqual(try row(id)?["status"], "expired")
    }

    /// Two prompts in a row: the first row was closed when the second
    /// opened, so a late answer to it never decides the second.
    func testALateAnswerToAnOlderPromptNeverDecidesTheNewerOne() async throws {
        let session = try await liveSession()
        let older = try await request(session, status: "answered_on_mac")
        let newer = try await request(session)

        let outcome = try await makeHandlers().handle(answer(session, request: older))

        XCTAssertEqual(outcome.reason, .notPending)
        XCTAssertEqual(try row(newer)?["status"], "pending")
    }

    func testProj21_RevokeBlocksAnswers() async throws {
        let session = try await liveSession()
        let first = try await request(session)
        let handlers = try makeHandlers()
        let allowed = try await handlers.handle(answer(session, request: first))
        XCTAssertEqual(allowed.status, .applied)
        let second = try await request(session)

        _ = try sidecar.setDeviceGrant(.permissions, false, deviceID: testPhoneID, at: Date())
        let outcome = try await handlers.handle(answer(session, request: second))

        XCTAssertEqual(outcome.reason, .deviceNotAllowed)
        XCTAssertEqual(try row(second)?["status"], "pending")
    }

    func testAnAnswerForAnotherSessionsRequestIsNotFound() async throws {
        let session = try await liveSession()
        let other = try await liveSession()
        let id = try await request(other)

        let outcome = try await makeHandlers().handle(answer(session, request: id))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .notFound)
        XCTAssertEqual(try row(id)?["status"], "pending")
    }

    func testAnAnswerForASessionNoLongerRunningFails() async throws {
        let session = try await liveSession()
        let id = try await request(session)
        await center.close(sessionID: session)

        let outcome = try await makeHandlers().handle(answer(session, request: id))

        XCTAssertEqual(outcome.reason, .sessionNotRunning)
        XCTAssertEqual(try row(id)?["status"], "pending")
    }

    func testAnAnswerWithBadParamsIsInvalid() async throws {
        let session = try await liveSession()
        let id = try await request(session)

        let outcome = try await makeHandlers().handle(answer(session, request: id, "always"))

        XCTAssertEqual(outcome.reason, .invalidParams)
        XCTAssertEqual(try row(id)?["status"], "pending")
    }

    /// Only the hook's JSON decides a prompt: an answer writes no byte to
    /// the terminal, whatever its state (PROJ-16 holds).
    func testProj21_AnAnswerTypesNothing() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)
        let handlers = try makeHandlers()
        let first = try await request(session)
        _ = try await handlers.handle(answer(session, request: first))
        let second = try await request(session)
        _ = try await handlers.handle(answer(session, request: second, "deny"))

        XCTAssertEqual(try row(first)?["status"], "allowed")
        XCTAssertEqual(try row(second)?["status"], "denied")
        XCTAssertTrue(typed.isEmpty)
    }

    // MARK: - Interrupt

    func testInterruptSendsOneEscWhileWorking() async throws {
        let session = try await liveSession()
        setState(session, .working)

        let outcome = try await makeHandlers().handle(interrupt(session))

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(typed, [[0x1B]])
    }

    /// Agents working counts as Working.
    func testInterruptSendsOneEscWhileAgentsWork() async throws {
        let session = try await liveSession()
        setState(session, .background)

        let outcome = try await makeHandlers().handle(interrupt(session))

        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(typed, [[0x1B]])
    }

    func testInterruptAtNeedsApprovalFailsNotWorking() async throws {
        let session = try await liveSession()
        setState(session, .needsApproval)

        let outcome = try await makeHandlers().handle(interrupt(session))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .notWorking)
        XCTAssertTrue(typed.isEmpty)
    }

    /// The prompt is drawn before its hook reports: the state still says
    /// Working, but a pending request means an Esc would reject the prompt.
    func testInterruptWithAPendingRequestFailsNotWorking() async throws {
        let session = try await liveSession()
        setState(session, .working)
        let id = try await request(session)

        let outcome = try await makeHandlers().handle(interrupt(session))

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.reason, .notWorking)
        XCTAssertEqual(outcome.errorMessage, "Needs approval — use Deny")
        XCTAssertEqual(try row(id)?["status"], "pending")
        XCTAssertTrue(typed.isEmpty)
    }

    func testInterruptWhenIdleFailsNotWorking() async throws {
        let session = try await liveSession()
        let handlers = try makeHandlers()
        for kind: SessionSwitcherPresentation.State.Kind in [.stopped, .running, .finished, .waitingOnAsk, .readyToCheck, .failed] {
            setState(session, kind)
            let outcome = try await handlers.handle(interrupt(session))
            XCTAssertEqual(outcome.reason, .notWorking, "\(kind)")
        }
        statuses[session] = nil
        let unknown = try await handlers.handle(interrupt(session))
        XCTAssertEqual(unknown.reason, .notWorking)
        XCTAssertTrue(typed.isEmpty)
    }

    func testAStaleInterruptExpires() async throws {
        let session = try await liveSession()
        setState(session, .working)

        let outcome = try await makeHandlers().handle(interrupt(session, age: 121))

        XCTAssertEqual(outcome, .expired)
        XCTAssertTrue(typed.isEmpty)
    }

    func testInterruptNeedsTheTypingGrant() async throws {
        let session = try await liveSession()
        setState(session, .working)
        _ = try sidecar.setDeviceGrant(.typing, false, deviceID: testPhoneID, at: Date())

        let outcome = try await makeHandlers().handle(interrupt(session))

        XCTAssertEqual(outcome.reason, .deviceNotAllowed)
        XCTAssertTrue(typed.isEmpty)
    }

    func testInterruptOfASessionNoLongerRunningFails() async throws {
        let session = try await liveSession()
        setState(session, .working)
        await center.close(sessionID: session)

        let outcome = try await makeHandlers().handle(interrupt(session))

        XCTAssertEqual(outcome.reason, .sessionNotRunning)
        XCTAssertTrue(typed.isEmpty)
    }

    /// A hub that dies after the Esc never replays it: the relay claims
    /// both kinds `begun` before their handler.
    func testBothKindsAreClaimedBeforeTheirHandler() {
        XCTAssertTrue(RelayProcessor.nonIdempotentKinds.isSuperset(of: PermissionAnswerHandlers.kinds))
    }
}
