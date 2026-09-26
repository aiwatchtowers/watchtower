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
        makeCenter(manager: manager) { _ in mock }
    }

    /// Per-target services: two briefs that must be told apart need two
    /// distinct mocks — one shared mock's accumulated `prompts` cannot
    /// distinguish "A then B" from "B twice".
    private func makeCenter(
        manager: DatabaseManager,
        serviceFor: @escaping (Target) -> MockClaudeService
    ) -> TargetBriefCenter {
        makeCenter { target in self.makeChatVM(manager, target: target, service: serviceFor(target)) }
    }

    /// A center whose factory hands out VMs the test holds itself — the
    /// production factory likewise returns the container's live VM, the one
    /// the owner may already be typing into while a brief is queued.
    private func makeCenter(chatVMFor: @escaping (Target) -> TargetChatViewModel?) -> TargetBriefCenter {
        let center = TargetBriefCenter()
        center.makeChatVM = chatVMFor
        return center
    }

    private func makeChatVM(
        _ manager: DatabaseManager, target: Target, service: any AIServiceProtocol
    ) -> TargetChatViewModel? {
        guard let conversationID = try? manager.dbPool.write({ db in
            try ChatConversationQueries.create(
                db, title: "Task", contextType: "target", contextID: String(target.id)
            ).id
        }) else { return nil }
        return TargetChatViewModel(
            target: target,
            viewModel: TargetsViewModel(dbManager: manager),
            dbManager: manager,
            conversationID: conversationID,
            aiService: service
        )
    }

    /// Poll until `condition` holds, failing the test at the deadline rather
    /// than after a fixed number of spins (wall-clock, not spin count).
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(label)", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    // Sync helper: inside async test methods GRDB's async read overload would
    // win inside an autoclosure; a sync func pins the sync overload.
    private func fetchTarget(_ manager: DatabaseManager, id: Int) throws -> Target? {
        try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) }
    }

    private func deleteTarget(_ manager: DatabaseManager, id: Int) throws {
        try manager.dbPool.write { db in try TargetQueries.delete(db, id: id) }
    }

    private func hasConversation(_ manager: DatabaseManager, targetID: Int) throws -> Bool {
        try manager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "target", id: String(targetID)) != nil
        }
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

    /// THE queue guard (owner decision 16): a second Enter-create queues
    /// behind the first instead of superseding it. Two targets and two
    /// DISTINCT mocks — a shared mock's accumulated `prompts` could not tell
    /// "A then B" from "B twice". A streams a complete execute-mode directive
    /// and then parks on a test-controlled gate, so the assertions below see a
    /// genuinely in-flight first brief.
    func testSecondBriefQueuesBehindTheFirstAndBothComplete() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let execBlock = """
        Working on it.
        ```watchtower-action
        { "type": "add_sub_item", "text": "decomposed step", "mode": "execute", "reason": "directive" }
        ```
        """
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text(execBlock)], thenAwaitsRelease: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        let center = makeCenter(manager: manager) { $0.id == targetA.id ? mockA : mockB }

        center.startBrief(target: targetA, text: "brief A")
        let vmA = try XCTUnwrap(center.adoptVM(for: targetA.id))
        await waitUntil("A's action block to arrive") {
            vmA.messages.last?.text.contains("watchtower-action") ?? false
        }

        center.startBrief(target: targetB, text: "brief B")

        // A keeps streaming — the whole point of the queue.
        XCTAssertTrue(vmA.isStreaming, "the second brief cancelled the first")
        XCTAssertEqual(center.phase(for: targetA.id), .briefing(targetID: targetA.id))
        XCTAssertEqual(center.phase(for: targetB.id), .queued(targetID: targetB.id))
        // … and B has NOT started: no prompt sent, no VM built, nothing
        // persisted. This is the assertion a one-target fixture cannot make.
        XCTAssertTrue(mockB.prompts.isEmpty, "B started while A was still streaming")
        XCTAssertNil(center.adoptVM(for: targetB.id))
        XCTAssertTrue(try fetchPersistedMessages(manager, targetID: targetB.id).isEmpty)

        // Release A: its execute directive must actually apply — the payload
        // the supersede destroyed.
        mockA.release()
        await waitUntil("A to finish") { center.phase(for: targetA.id) == .idle }

        let afterA = try XCTUnwrap(fetchTarget(manager, id: targetA.id))
        XCTAssertTrue(afterA.decodedSubItems.contains { $0.text == "decomposed step" },
                      "A's execute-mode directive never applied")
        XCTAssertEqual(mockA.prompts, ["brief A"])
        let persistedA = try fetchPersistedMessages(manager, targetID: targetA.id)
        XCTAssertEqual(persistedA.filter { $0.role == "user" }.map(\.text), ["brief A"])
        XCTAssertEqual(persistedA.filter { $0.role == "assistant" }.count, 1)

        // Only then does B run, exactly once.
        await waitUntil("B to finish") { center.phase(for: targetB.id) == .idle && !mockB.prompts.isEmpty }
        XCTAssertEqual(mockB.prompts, ["brief B"])
        let persistedB = try fetchPersistedMessages(manager, targetID: targetB.id)
        XCTAssertEqual(persistedB.filter { $0.role == "user" }.map(\.text), ["brief B"])
        XCTAssertEqual(persistedB.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(center.phase, .idle)
    }

    /// A failed brief is per target and never blocks the jobs behind it: A
    /// fails, B still runs to completion, and A's failure is still on screen
    /// afterwards (until it is dismissed).
    func testFailedBriefKeepsItsBannerAndDoesNotBlockTheQueue() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "CLI unavailable" }
        }
        let mockA = MockClaudeService(error: Boom())
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        let center = makeCenter(manager: manager) { $0.id == targetA.id ? mockA : mockB }

        center.startBrief(target: targetA, text: "brief A")
        center.startBrief(target: targetB, text: "brief B")
        XCTAssertEqual(center.phase(for: targetB.id), .queued(targetID: targetB.id))

        await waitUntil("A to fail") {
            center.phase(for: targetA.id) == .failed(targetID: targetA.id, message: "CLI unavailable")
        }
        await waitUntil("B to finish") { center.phase(for: targetB.id) == .idle && !mockB.prompts.isEmpty }

        XCTAssertEqual(mockB.prompts, ["brief B"])
        let persistedB = try fetchPersistedMessages(manager, targetID: targetB.id)
        XCTAssertEqual(persistedB.filter { $0.role == "assistant" }.count, 1)
        // A's banner is still up after B came and went.
        XCTAssertEqual(center.phase(for: targetA.id),
                       .failed(targetID: targetA.id, message: "CLI unavailable"))

        center.dismissFailure(targetID: targetA.id)
        XCTAssertEqual(center.phase(for: targetA.id), .idle)
        XCTAssertEqual(center.phase, .idle)
    }

    /// The `CreateTargetSheet` hand-off failure path is per target too:
    /// recording B's failure must not reach into A's running brief (the
    /// second half of the single-slot bug — `markFailed` used to cancel it).
    func testMarkFailedForAnotherTargetLeavesTheRunningBriefAlone() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("working on it")],
                                      thenAwaitsRelease: true)
        let center = makeCenter(manager: manager, mock: mockA)

        center.startBrief(target: targetA, text: "brief A")
        let vmA = try XCTUnwrap(center.adoptVM(for: targetA.id))
        await waitUntil("A's text to arrive") {
            vmA.messages.last?.text.contains("working on it") ?? false
        }

        center.markFailed(targetID: targetB.id, message: "Couldn't start the brief")

        XCTAssertTrue(vmA.isStreaming, "markFailed for another target cancelled the running brief")
        XCTAssertEqual(center.phase(for: targetA.id), .briefing(targetID: targetA.id))
        XCTAssertEqual(center.phase(for: targetB.id),
                       .failed(targetID: targetB.id, message: "Couldn't start the brief"))

        mockA.release()
        await waitUntil("A to finish") { center.phase(for: targetA.id) == .idle }
        let persistedA = try fetchPersistedMessages(manager, targetID: targetA.id)
        XCTAssertEqual(persistedA.filter { $0.role == "assistant" }.count, 1)
        // B's hand-off failure is untouched by A completing.
        XCTAssertEqual(center.phase(for: targetB.id),
                       .failed(targetID: targetB.id, message: "Couldn't start the brief"))
    }

    /// An EXPLICIT cancel (the only cancel the spec sanctions — the owner
    /// closing the chat mid-run) must produce NO writes: no auto-applied
    /// action, even for an execute block that fully streamed before the
    /// cancel, no action cards, no duplicate assistant persist and no system
    /// message. Inherited from the retired supersede test, which pinned the
    /// same absence on a cancel the center no longer performs.
    func testExplicitCancelWritesNothing() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager, text: "target A")
        let execBlock = """
        Working on it.
        ```watchtower-action
        { "type": "add_sub_item", "text": "sneaky step", "mode": "execute", "reason": "directive" }
        ```
        """
        let mock = MockClaudeService(events: [.sessionID("s1"), .text(execBlock)], thenHangs: true)
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "brief A")
        let vm = try XCTUnwrap(center.adoptVM(for: target.id))
        // Wait until the action block has actually arrived, so the cancel
        // below interrupts a run that HAS a parseable directive.
        await waitUntil("the action block to arrive") {
            vm.messages.last?.text.contains("watchtower-action") ?? false
        }
        XCTAssertTrue(vm.isStreaming)

        vm.cancelStream()
        XCTAssertFalse(vm.isStreaming)

        // Give the cancelled executeStream a chance to run its tail (a bounded
        // settle window — we assert an ABSENCE, so there is no condition to
        // await), then assert the cancelled run wrote NOTHING:
        let settleDeadline = Date().addingTimeInterval(0.2)
        while Date() < settleDeadline { await Task.yield() }
        let after = try XCTUnwrap(fetchTarget(manager, id: target.id))
        XCTAssertFalse(after.decodedSubItems.contains { $0.text == "sneaky step" },
                       "cancelled run auto-applied an action after cancel")
        XCTAssertTrue(vm.actionCards.isEmpty, "cancelled run surfaced action cards")
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertLessThanOrEqual(persisted.filter { $0.role == "assistant" }.count, 1,
                                 "partial assistant text persisted twice")
        XCTAssertFalse(persisted.contains { $0.role == "system" },
                       "cancelled run persisted a summary/failure message")

        // The center's watcher sees the stream end and releases the slot.
        await center.task?.value
        XCTAssertEqual(center.phase(for: target.id), .idle)
    }

    /// Failures are per target and stay visible until dismissed (owner
    /// decision 16, the `MeetingRecorderCenter` precedent): starting a brief
    /// for B does NOT clear A's failure banner.
    func testStartingAnotherBriefKeepsTheEarlierFailureVisible() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "CLI unavailable" }
        }
        let mockA = MockClaudeService(error: Boom())
        let mockB = MockClaudeService(events: [.sessionID("s2"), .text("ok"), .done])
        let center = makeCenter(manager: manager) { $0.id == targetA.id ? mockA : mockB }

        center.startBrief(target: targetA, text: "brief A")
        await waitUntil("A to fail") {
            center.phase(for: targetA.id) == .failed(targetID: targetA.id, message: "CLI unavailable")
        }

        center.startBrief(target: targetB, text: "brief B")
        XCTAssertEqual(center.phase(for: targetB.id), .briefing(targetID: targetB.id))
        // A's failure survives B's whole run — only an explicit dismissal
        // clears it.
        XCTAssertEqual(center.phase(for: targetA.id),
                       .failed(targetID: targetA.id, message: "CLI unavailable"))

        await waitUntil("B to finish") { center.phase(for: targetB.id) == .idle }
        XCTAssertEqual(center.phase(for: targetA.id),
                       .failed(targetID: targetA.id, message: "CLI unavailable"))
        // The head projection surfaces that lingering failure.
        XCTAssertEqual(center.phase, .failed(targetID: targetA.id, message: "CLI unavailable"))

        center.dismissFailure(targetID: targetA.id)
        XCTAssertEqual(center.phase, .idle)
    }

    /// `markFailed` (the CreateTargetSheet hand-off failure path) lands on
    /// the same `.failed` phase a failed run does; `dismissFailure` clears
    /// it and nothing else.
    func testMarkFailedAndDismissFailure() {
        let center = TargetBriefCenter()

        center.dismissFailure(targetID: 7)  // no-op on idle
        XCTAssertEqual(center.phase, .idle)

        center.markFailed(targetID: 7, message: "Couldn't start the brief")
        XCTAssertEqual(center.phase, .failed(targetID: 7, message: "Couldn't start the brief"))
        XCTAssertEqual(center.phase(for: 7), .failed(targetID: 7, message: "Couldn't start the brief"))

        center.dismissFailure(targetID: 7)
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

    /// The owner can reach a QUEUED target's live chat and start their own
    /// turn there. When the brief falls due on that busy VM, `send()` would
    /// no-op and the watcher would take the owner's run for the brief's — the
    /// brief must fail visibly instead, and never reach the model.
    func testBriefDueOnABusyChatFailsVisibly() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenAwaitsRelease: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("owner reply")], thenAwaitsRelease: true)
        let vmB = try XCTUnwrap(makeChatVM(manager, target: targetB, service: mockB))
        let center = makeCenter { target in
            target.id == targetA.id ? self.makeChatVM(manager, target: target, service: mockA) : vmB
        }

        center.startBrief(target: targetA, text: "brief A")
        center.startBrief(target: targetB, text: "brief B")
        XCTAssertEqual(center.phase(for: targetB.id), .queued(targetID: targetB.id))

        // The owner, landed on B's chat, starts a turn of their own.
        vmB.inputText = "owner message"
        vmB.send()
        XCTAssertTrue(vmB.isStreaming)

        mockA.release()
        let busy = "The chat was busy when this brief was due — re-ask here."
        await waitUntil("B to fail on the busy chat") {
            center.phase(for: targetB.id) == .failed(targetID: targetB.id, message: busy)
        }
        // The owner's own run finishes; B's failure must outlive it.
        mockB.release()
        await waitUntil("the owner's run to end") { !vmB.isStreaming }
        XCTAssertEqual(center.phase(for: targetB.id), .failed(targetID: targetB.id, message: busy))
        XCTAssertEqual(mockB.prompts, ["owner message"])
        XCTAssertFalse(mockB.prompts.contains("brief B"), "the brief reached the model through the busy chat")
    }

    /// An unsent owner draft in a queued target's chat survives the brief:
    /// the brief is still sent exactly once, and the draft is back in the
    /// input afterwards.
    func testBriefKeepsTheOwnersUnsentDraft() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenAwaitsRelease: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        let vmB = try XCTUnwrap(makeChatVM(manager, target: targetB, service: mockB))
        let center = makeCenter { target in
            target.id == targetA.id ? self.makeChatVM(manager, target: target, service: mockA) : vmB
        }

        center.startBrief(target: targetA, text: "brief A")
        center.startBrief(target: targetB, text: "brief B")
        vmB.inputText = "half-typed draft"

        mockA.release()
        await waitUntil("B to start") { !mockB.prompts.isEmpty }
        XCTAssertEqual(vmB.inputText, "half-typed draft", "the brief overwrote the owner's draft")
        await waitUntil("B to finish") { center.phase(for: targetB.id) == .idle }

        XCTAssertEqual(mockB.prompts, ["brief B"])
        let persistedB = try fetchPersistedMessages(manager, targetID: targetB.id)
        XCTAssertEqual(persistedB.filter { $0.role == "user" }.map(\.text), ["brief B"])
        XCTAssertEqual(vmB.inputText, "half-typed draft")
    }

    /// Degenerate-but-valid input: a brief `send()` refuses (blank text)
    /// must not pass for a finished one.
    func testBriefThatCannotBeSentFailsVisibly() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        let mock = MockClaudeService(events: [.sessionID("s1"), .text("ok"), .done])
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "  \n ")

        XCTAssertEqual(center.phase(for: target.id),
                       .failed(targetID: target.id, message: "The brief could not be sent — re-ask here."))
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertNil(center.adoptVM(for: target.id))
    }

    /// The owner explicitly cancelling the running brief frees the slot: the
    /// brief queued behind it starts and completes.
    func testExplicitCancelOfTheRunningBriefStartsTheQueuedOne() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenHangs: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        let center = makeCenter(manager: manager) { $0.id == targetA.id ? mockA : mockB }

        center.startBrief(target: targetA, text: "brief A")
        let vmA = try XCTUnwrap(center.adoptVM(for: targetA.id))
        center.startBrief(target: targetB, text: "brief B")
        await waitUntil("A's text to arrive") { vmA.messages.last?.text.contains("A working") ?? false }
        XCTAssertTrue(mockB.prompts.isEmpty)

        vmA.cancelStream()

        await waitUntil("B to finish") { center.phase(for: targetB.id) == .idle && !mockB.prompts.isEmpty }
        XCTAssertEqual(center.phase(for: targetA.id), .idle)
        XCTAssertEqual(mockB.prompts, ["brief B"])
        let persistedB = try fetchPersistedMessages(manager, targetID: targetB.id)
        XCTAssertEqual(persistedB.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(center.phase, .idle)
    }

    /// A cancelled completion watcher still settles its job and drains, so
    /// the queue behind it can never be stranded with the slot held — and it
    /// stops its own stream first, so "one at a time" holds: B must not start
    /// while A still streams unobserved.
    func testCancelledWatcherDoesNotStrandTheQueue() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenAwaitsRelease: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        var vmA: TargetChatViewModel?
        var aStreamingWhenBStarted = true
        let center = makeCenter { target in
            if target.id == targetA.id { return self.makeChatVM(manager, target: target, service: mockA) }
            aStreamingWhenBStarted = vmA?.isStreaming ?? true
            return self.makeChatVM(manager, target: target, service: mockB)
        }
        defer { mockA.release() }

        center.startBrief(target: targetA, text: "brief A")
        vmA = try XCTUnwrap(center.adoptVM(for: targetA.id))
        center.startBrief(target: targetB, text: "brief B")
        XCTAssertEqual(vmA?.isStreaming, true)
        let watcherA = try XCTUnwrap(center.task)
        watcherA.cancel()
        await watcherA.value

        XCTAssertEqual(vmA?.isStreaming, false, "the cancelled watcher left A streaming")
        XCTAssertFalse(aStreamingWhenBStarted, "B started while A was still streaming")
        await waitUntil("B to finish") { center.phase(for: targetB.id) == .idle && !mockB.prompts.isEmpty }
        XCTAssertEqual(mockB.prompts, ["brief B"])
    }

    /// A target deleted while its brief waits must never get the brief: no
    /// conversation is minted for the dead id and no model call is made. The
    /// row delete alone (no `drop`) must be enough — the drain re-checks.
    func testBriefForATargetDeletedWhileQueuedNeverRuns() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenAwaitsRelease: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        let center = makeCenter(manager: manager) { $0.id == targetA.id ? mockA : mockB }
        center.targetExists = { id in (try? self.fetchTarget(manager, id: id)) != nil }

        center.startBrief(target: targetA, text: "brief A")
        center.startBrief(target: targetB, text: "brief B")
        XCTAssertEqual(center.phase(for: targetB.id), .queued(targetID: targetB.id))
        try deleteTarget(manager, id: targetB.id)

        mockA.release()
        await waitUntil("A to finish") { center.phase(for: targetA.id) == .idle }
        await waitUntil("B's job to go") { center.phase(for: targetB.id) == .idle }

        XCTAssertTrue(mockB.prompts.isEmpty, "the deleted target's brief reached the model")
        XCTAssertFalse(try hasConversation(manager, targetID: targetB.id),
                       "a conversation was minted for the deleted target")
        XCTAssertEqual(center.phase, .idle)
    }

    /// The delete paths' half: `drop(targetID:)` forgets that target's queued
    /// AND failed jobs, and nothing of any other target's.
    func testDropForgetsTheTargetsQueuedAndFailedBriefsOnly() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenAwaitsRelease: true)
        let mockB = MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        let center = makeCenter(manager: manager) { $0.id == targetA.id ? mockA : mockB }

        center.startBrief(target: targetA, text: "brief A")
        center.markFailed(targetID: targetB.id, message: "Couldn't start the brief")
        center.startBrief(target: targetB, text: "brief B")

        center.drop(targetID: targetB.id)
        XCTAssertEqual(center.phase(for: targetB.id), .idle, "B's queued or failed job survived the drop")
        // Dropping a target whose brief is streaming leaves that run alone.
        center.drop(targetID: targetA.id)
        XCTAssertEqual(center.phase(for: targetA.id), .briefing(targetID: targetA.id))

        mockA.release()
        await waitUntil("A to finish") { center.phase(for: targetA.id) == .idle }
        XCTAssertTrue(mockB.prompts.isEmpty, "a dropped brief still ran")
        XCTAssertFalse(try hasConversation(manager, targetID: targetB.id))
        XCTAssertEqual(center.phase, .idle)
    }

    /// The brief runs on the container's LIVE VM, which may carry an error
    /// from an earlier owner turn; a brief that then succeeds must not be
    /// reported as failed with that stale message.
    func testAnEarlierFailedOwnerTurnDoesNotFailALaterBrief() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let targetA = try makeTarget(manager, text: "target A")
        let targetB = try makeTarget(manager, text: "target B")
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "owner turn failed" }
        }
        let mockA = MockClaudeService(events: [.sessionID("a1"), .text("A working")], thenAwaitsRelease: true)
        let serviceB = FailsFirstService(
            failing: MockClaudeService(error: Boom()),
            succeeding: MockClaudeService(events: [.sessionID("b1"), .text("B reply"), .done])
        )
        let vmB = try XCTUnwrap(makeChatVM(manager, target: targetB, service: serviceB))
        let center = makeCenter { target in
            target.id == targetA.id ? self.makeChatVM(manager, target: target, service: mockA) : vmB
        }

        center.startBrief(target: targetA, text: "brief A")
        center.startBrief(target: targetB, text: "brief B")
        // The owner, landed on B's chat, sends a turn of their own that fails.
        vmB.inputText = "owner message"
        vmB.send()
        await waitUntil("the owner's turn to fail") { !vmB.isStreaming && vmB.errorMessage != nil }

        mockA.release()
        await waitUntil("B's brief to finish") {
            !serviceB.succeeding.prompts.isEmpty && center.phase(for: targetB.id) != .queued(targetID: targetB.id)
                && center.phase(for: targetB.id) != .briefing(targetID: targetB.id)
        }
        XCTAssertEqual(serviceB.succeeding.prompts, ["brief B"])
        XCTAssertEqual(center.phase(for: targetB.id), .idle, "a stale owner-turn error failed the brief")
    }

    /// Dismissing one target's failure leaves another target's failure up.
    func testDismissFailureClearsOnlyThatTarget() {
        let center = TargetBriefCenter()
        center.markFailed(targetID: 1, message: "A failed")
        center.markFailed(targetID: 2, message: "B failed")

        center.dismissFailure(targetID: 1)

        XCTAssertEqual(center.phase(for: 1), .idle)
        XCTAssertEqual(center.phase(for: 2), .failed(targetID: 2, message: "B failed"))
    }
}

/// Fails the first stream (an owner turn) and serves every later one from a
/// second mock — the "earlier error on the live VM" fixture.
private final class FailsFirstService: AIServiceProtocol, @unchecked Sendable {
    let failing: MockClaudeService
    let succeeding: MockClaudeService
    private let lock = NSLock()
    private var calls = 0

    init(failing: MockClaudeService, succeeding: MockClaudeService) {
        self.failing = failing
        self.succeeding = succeeding
    }

    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let first: Bool = lock.withLock {
            calls += 1
            return calls == 1
        }
        return (first ? failing : succeeding).stream(
            prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID, dbPath: dbPath,
            model: model, provider: provider, toolMode: toolMode
        )
    }
}
