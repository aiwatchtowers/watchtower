import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TargetBriefCenterTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager, text: String = "ship feature") throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text,
                                     periodStart: "2026-08-01", periodEnd: "2026-08-31")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    private func ensureChatTables(_ manager: DatabaseManager) throws {
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
    }

    private func makeCenter(manager: DatabaseManager, mock: MockClaudeService) -> TargetBriefCenter {
        let center = TargetBriefCenter()
        center.makeChatVM = { target in
            TargetChatViewModel(
                target: target,
                viewModel: TargetsViewModel(dbManager: manager),
                dbManager: manager,
                aiService: mock
            )
        }
        return center
    }

    // Sync helper: inside async test methods GRDB's async read overload would
    // win inside an autoclosure; a sync func pins the sync overload.
    private func fetchTarget(_ manager: DatabaseManager, id: Int) throws -> Target? {
        try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) }
    }

    private func fetchPersistedMessages(_ manager: DatabaseManager, targetID: Int) throws -> [ChatMessageRecord] {
        try manager.dbPool.read { db in
            guard let conv = try ChatConversationQueries.fetchByContext(
                db, type: "target", id: String(targetID)
            ) else { return [] }
            return try ChatMessageQueries.fetchByConversation(db, conversationID: conv.id)
        }
    }

    /// The house "started → navigated away → came back" contract: the run
    /// lives on the center, not on any view — no view ever held the VM here,
    /// yet the run streams to completion, the message rides the VM's normal
    /// persistence path, and the center releases to idle.
    func testBriefSurvivesWithNoViewAndReleasesToIdle() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        let mock = MockClaudeService(events: [.sessionID("s1"), .text("On it — decomposing."), .done])
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "Ship feature\n\nWalk the transcripts and break it down.")

        XCTAssertEqual(center.phase, .briefing(targetID: target.id))
        // The detail view for this target adopts the center's VM …
        XCTAssertNotNil(center.adoptVM(for: target.id))
        // … while any other target gets nil (fresh VM as today).
        XCTAssertNil(center.adoptVM(for: target.id + 999))

        await center.task?.value

        XCTAssertEqual(center.phase, .idle)
        // Released after completion — a detail view opened now rebuilds from
        // the persisted conversation instead.
        XCTAssertNil(center.adoptVM(for: target.id))

        // The composer text was sent as the first owner message through the
        // VM's normal send path, and the reply persisted alongside it.
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertEqual(mock.prompts[0], "Ship feature\n\nWalk the transcripts and break it down.")
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(persisted.first { $0.role == "user" }?.text,
                       "Ship feature\n\nWalk the transcripts and break it down.")
        XCTAssertEqual(persisted.filter { $0.role == "assistant" }.count, 1)
    }

    /// An adopted VM stays alive with the adopting view: adoption returns the
    /// SAME instance for repeated calls while the run is held, so a view and
    /// the center never race one conversation with two VMs.
    func testAdoptionReturnsTheSameInstanceWhileHeld() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        let mock = MockClaudeService(events: [.sessionID("s1"), .text("ok"), .done])
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "brief text")
        let first = center.adoptVM(for: target.id)
        let second = center.adoptVM(for: target.id)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)

        await center.task?.value
        // The adopted instance survives the center's release (the view holds it).
        XCTAssertNotNil(first)
        XCTAssertEqual(center.phase, .idle)
    }

    func testStreamFailureLandsInFailed() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "CLI unavailable" }
        }
        let mock = MockClaudeService(error: Boom())
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "brief text")
        await center.task?.value

        // Failed carries the target id so the detail view can show the
        // failure banner for exactly this target; it is NOT auto-cleared.
        XCTAssertEqual(center.phase, .failed(targetID: target.id, message: "CLI unavailable"))
        XCTAssertNil(center.adoptVM(for: target.id))
        // The instruction survives as a persisted chat message (spec §7) —
        // the owner re-asks in the chat.
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.filter { $0.role == "user" }.map(\.text), ["brief text"])
    }

    /// Single-slot supersede: starting a brief for B while A is still
    /// streaming must actually CANCEL A's stream — and a cancelled run must
    /// produce NO writes: no auto-applied actions (even for an execute block
    /// that fully streamed before the cancel) and no duplicate assistant
    /// persist. Pins the "superseded run can never auto-apply invisibly"
    /// contract, not just the isStreaming flag.
    func testNewBriefCancelsTheSupersededStream() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        // A's run streams a COMPLETE execute-mode action block, then hangs
        // mid-stream — only the supersede's cancel ends it.
        let execBlock = """
        Working on it.
        ```watchtower-action
        { "type": "add_sub_item", "text": "sneaky step", "mode": "execute", "reason": "directive" }
        ```
        """
        let mock = MockClaudeService(events: [.sessionID("s1"), .text(execBlock)], thenHangs: true)
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: targetA, text: "brief A")
        let vmA = try XCTUnwrap(center.adoptVM(for: targetA.id))
        // Wait until the action block has actually arrived in A's stream, so
        // the supersede below interrupts a run that HAS a parseable directive.
        let deadline = Date().addingTimeInterval(5)
        while !(vmA.messages.last?.text.contains("watchtower-action") ?? false) {
            guard Date() < deadline else { return XCTFail("A's stream never delivered the block") }
            await Task.yield()
        }
        XCTAssertTrue(vmA.isStreaming)

        center.startBrief(target: targetB, text: "brief B")

        XCTAssertFalse(vmA.isStreaming)
        XCTAssertNil(center.adoptVM(for: targetA.id))
        XCTAssertEqual(center.phase, .briefing(targetID: targetB.id))
        XCTAssertNotNil(center.adoptVM(for: targetB.id))

        // Give A's cancelled executeStream a chance to run its tail (a
        // bounded settle window — we assert an ABSENCE, so there is no
        // condition to await), then assert the superseded run wrote NOTHING:
        let settleDeadline = Date().addingTimeInterval(0.2)
        while Date() < settleDeadline { await Task.yield() }
        let afterA = try XCTUnwrap(fetchTarget(manager, id: targetA.id))
        XCTAssertFalse(afterA.decodedSubItems.contains { $0.text == "sneaky step" },
                       "superseded run auto-applied an action after cancel")
        XCTAssertTrue(vmA.actionCards.isEmpty, "superseded run surfaced action cards")
        let persistedA = try fetchPersistedMessages(manager, targetID: targetA.id)
        XCTAssertLessThanOrEqual(persistedA.filter { $0.role == "assistant" }.count, 1,
                                 "partial assistant text persisted twice")
        XCTAssertFalse(persistedA.contains { $0.role == "system" },
                       "cancelled run persisted a summary/failure message")

        // Clean up the hanging B run.
        center.adoptVM(for: targetB.id)?.cancelStream()
        center.task?.cancel()
    }

    /// A lingering `.failed` is cleared when the next brief starts — never
    /// silently in between.
    func testStartBriefClearsPriorFailure() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "CLI unavailable" }
        }
        let center = makeCenter(manager: manager, mock: MockClaudeService(error: Boom()))

        center.startBrief(target: targetA, text: "brief A")
        await center.task?.value
        XCTAssertEqual(center.phase, .failed(targetID: targetA.id, message: "CLI unavailable"))

        // Swap in a healthy factory for the second run.
        let okMock = MockClaudeService(events: [.sessionID("s2"), .text("ok"), .done])
        center.makeChatVM = { target in
            TargetChatViewModel(
                target: target,
                viewModel: TargetsViewModel(dbManager: manager),
                dbManager: manager,
                aiService: okMock
            )
        }
        center.startBrief(target: targetB, text: "brief B")
        XCTAssertEqual(center.phase, .briefing(targetID: targetB.id))

        await center.task?.value
        XCTAssertEqual(center.phase, .idle)
    }

    /// `markFailed` (the CreateTargetSheet hand-off failure path) lands on
    /// the same `.failed` phase a failed run does; `dismissFailure` clears
    /// it and nothing else.
    func testMarkFailedAndDismissFailure() {
        let center = TargetBriefCenter()

        center.dismissFailure()  // no-op on idle
        XCTAssertEqual(center.phase, .idle)

        center.markFailed(targetID: 7, message: "Couldn't start the brief")
        XCTAssertEqual(center.phase, .failed(targetID: 7, message: "Couldn't start the brief"))

        center.dismissFailure()
        XCTAssertEqual(center.phase, .idle)
    }

    /// Degenerate-but-valid input: no factory wired (DB never opened) fails
    /// cleanly instead of crashing or silently idling.
    func testMissingFactoryFailsCleanly() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let center = TargetBriefCenter()

        center.startBrief(target: target, text: "brief text")

        XCTAssertEqual(center.phase, .failed(targetID: target.id, message: "Database not available"))
        XCTAssertNil(center.adoptVM(for: target.id))
    }
}
