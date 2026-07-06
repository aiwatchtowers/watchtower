import GRDB
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Wiring tests for the Task 7 Chat tab: composer send → `ChatAssembler`
/// (user turn + assistant placeholder + relay record), chunk ingest → the
/// thread observation grows and completes, error styling driven by the
/// `isError` FLAG (never by sniffing the text), the whitespace send gate,
/// and the unreachable-banner state math. The Kit's own suites cover the
/// ChatAssembler/RelayFeed logic — here we prove the APP's glue over them.
@MainActor
final class ChatWiringTests: XCTestCase {

    // MARK: - Fixtures

    /// One transport shared by assembler and assertions — the same
    /// single-transport shape `AppEnvironment` wires in production.
    private struct Fixture {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let assembler: ChatAssembler
    }

    private func makeFixture(now: (@Sendable () -> Date)? = nil) throws -> Fixture {
        let store = try ReplicaStore(path: makeReplicaPath())
        let transport = InMemoryCloudTransport()
        let assembler: ChatAssembler = if let now {
            ChatAssembler(transport: transport, store: store, now: now)
        } else {
            ChatAssembler(transport: transport, store: store)
        }
        return Fixture(transport: transport, store: store, assembler: assembler)
    }

    /// Isolated on-disk pool path (the production DatabasePool mechanism).
    private func makeReplicaPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("replica.sqlite").path
    }

    /// A started thread VM with a fixed reachability answer (banner math has
    /// its own dedicated test below).
    private func makeThreadVM(_ fx: Fixture, sessionID: String? = nil, reachable: Bool = true) -> ChatThreadViewModel {
        let vm = ChatThreadViewModel()
        vm.start(store: fx.store, assembler: fx.assembler, isReachable: { _ in reachable }, sessionID: sessionID)
        return vm
    }

    /// Polls the main run loop until `condition` holds or the timeout elapses
    /// (observation callbacks arrive async on the main queue).
    private func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    // MARK: - Send through the VM (composer path)

    /// Composer send: ONE call into `assembler.send` yields the trimmed user
    /// turn + the empty assistant placeholder locally, the session header
    /// with a first-words title, and exactly one `chat_message` relay record
    /// — and the VM adopts the new session + clears the draft (success only).
    func testSendThroughVMPersistsTurnPlaceholderAndRelayRecord() async throws {
        let fx = try makeFixture()
        let vm = makeThreadVM(fx)

        vm.draft = "  What changed today?  "
        await vm.send()

        XCTAssertEqual(vm.draft, "", "draft clears on successful send")
        let sessionID = try XCTUnwrap(vm.sessionID, "the first send must adopt the minted session")

        // Local rows: the trimmed user turn (born complete) + the assistant
        // placeholder the streamed chunks will fill.
        let messages = try fx.store.chatMessages(inSession: sessionID)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.first?.text, "What changed today?")
        XCTAssertEqual(messages.first?.isComplete, true)
        XCTAssertEqual(messages.last?.text, "")
        XCTAssertEqual(messages.last?.isComplete, false)

        // Session header: first-words title, recent-first accessor.
        let sessions = try fx.store.chatSessions()
        XCTAssertEqual(sessions.map(\.id), [sessionID])
        XCTAssertEqual(sessions.first?.title, "What changed today?")

        // The wire: exactly one chat_message relay record, trimmed text.
        let batch = try await fx.transport.changes(in: .relay, since: nil)
        let sent = batch.changed.filter { $0.kind == RelayRecordKind.chatMessage.rawValue }
        XCTAssertEqual(sent.count, 1)
        let payload = try RelayCoder.makeDecoder()
            .decode(ChatMessagePayload.self, from: XCTUnwrap(sent.first).payload)
        XCTAssertEqual(payload.text, "What changed today?")
        XCTAssertEqual(payload.sessionID, sessionID)

        // The thread observation surfaces both rows to the view.
        try await poll { vm.messages.count == 2 }
    }

    /// Task 5 review note: a blank-titled session must be unreachable via the
    /// UI. `canSend` gates the button AND `send()` itself is a no-op on
    /// whitespace-only drafts (belt to the button's suspenders).
    func testWhitespaceDraftCannotSend() async throws {
        let fx = try makeFixture()
        let vm = makeThreadVM(fx)

        for draft in ["", "   ", " \n\t "] {
            vm.draft = draft
            XCTAssertFalse(vm.canSend, "send must be disabled for \(draft.debugDescription)")
            await vm.send()
        }

        XCTAssertNil(vm.sessionID)
        XCTAssertTrue(try fx.store.chatSessions().isEmpty, "a blank send would mint a blank-titled session")
        let batch = try await fx.transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty, "nothing may reach the wire for a blank draft")

        vm.draft = "  real question  "
        XCTAssertTrue(vm.canSend)
    }

    // MARK: - Ingest → observation (streaming path)

    /// A chunk sequence through the assembler: the thread VM's observed reply
    /// text GROWS chunk by chunk (typing state stays on) and flips complete
    /// at the done chunk — the exact signal the bubble view renders.
    func testIngestSequenceGrowsThreadTextAndCompletes() async throws {
        let fx = try makeFixture()
        let vm = makeThreadVM(fx)
        vm.draft = "Stream me an answer"
        await vm.send()
        try await poll { vm.messages.count == 2 }
        let sessionID = try XCTUnwrap(vm.sessionID)
        let replyID = try XCTUnwrap(vm.messages.last?.id)

        try await fx.assembler.ingest(
            ChatChunkPayload(sessionID: sessionID, messageID: replyID, seq: 0, text: "Hello", done: false)
        )
        try await poll { vm.messages.last?.text == "Hello" }
        XCTAssertEqual(vm.messages.last?.isComplete, false, "still streaming — typing indicator stays on")

        try await fx.assembler.ingest(
            ChatChunkPayload(sessionID: sessionID, messageID: replyID, seq: 1, text: ", world.", done: false)
        )
        try await poll { vm.messages.last?.text == "Hello, world." }

        try await fx.assembler.ingest(
            ChatChunkPayload(sessionID: sessionID, messageID: replyID, seq: 2, text: " Done.", done: true)
        )
        try await poll { vm.messages.last?.isComplete == true }
        XCTAssertEqual(vm.messages.last?.text, "Hello, world. Done.")
        XCTAssertEqual(vm.messages.last?.isError, false)
    }

    // MARK: - Error styling (flag-driven, NEVER prefix-sniffing)

    /// The error bubble is keyed EXCLUSIVELY off `isError`: an error-flagged
    /// reply styles as `.error` even though legacy desktops also prefix the
    /// text with "⚠️ " — and a SUCCESSFUL reply whose text merely starts
    /// with the same glyph must style as a normal assistant bubble.
    func testErrorStylingIsFlagDrivenNeverPrefixSniffed() async throws {
        let fx = try makeFixture()
        let vm = makeThreadVM(fx)
        vm.draft = "Will this fail?"
        await vm.send()
        try await poll { vm.messages.count == 2 }
        let sessionID = try XCTUnwrap(vm.sessionID)
        let failedReplyID = try XCTUnwrap(vm.messages.last?.id)

        try await fx.assembler.ingest(
            ChatChunkPayload(
                sessionID: sessionID, messageID: failedReplyID,
                seq: 0, text: "⚠️ Stream failed", done: true, isError: true
            )
        )
        try await poll { vm.messages.last?.isComplete == true }
        let failed = try XCTUnwrap(vm.messages.last)
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(ChatBubbleStyle.style(for: failed), .error)

        // Control: same glyph, flag false → NOT an error bubble.
        vm.draft = "Quote me a warning sign"
        await vm.send()
        try await poll { vm.messages.count == 4 }
        let controlReplyID = try XCTUnwrap(vm.messages.last?.id)
        try await fx.assembler.ingest(
            ChatChunkPayload(
                sessionID: sessionID, messageID: controlReplyID,
                seq: 0, text: "⚠️ means warning", done: true
            )
        )
        try await poll { vm.messages.last?.isComplete == true }
        let control = try XCTUnwrap(vm.messages.last)
        XCTAssertFalse(control.isError)
        XCTAssertEqual(
            ChatBubbleStyle.style(for: control), .assistant,
            "a successful reply must not be error-styled because of its text"
        )

        // User turns are user-styled regardless of content.
        XCTAssertEqual(ChatBubbleStyle.style(for: try XCTUnwrap(vm.messages.first)), .user)
    }

    // MARK: - Unreachable banners (heartbeat + first-chunk wait)

    /// Both banner triggers, on frozen clocks: (a) heartbeat never/stale →
    /// the tab-level banner, through the same `RelayFeed.isDesktopReachable`
    /// read the app wires in; (b) an assistant reply still empty past
    /// `ChatAssembler.unreachableAfter` (45 s) → the inline banner at the
    /// message, clearing the moment the first chunk lands.
    func testUnreachableBannerStateMath() async throws {
        // (a) Heartbeat liveness → tab banner.
        let fx = try makeFixture()
        let outbox = ActionOutbox(transport: fx.transport, store: fx.store)
        let feed = RelayFeed(transport: fx.transport, store: fx.store, outbox: outbox, assembler: fx.assembler)
        let sessionsVM = ChatSessionsViewModel()
        sessionsVM.start(store: fx.store, isReachable: feed.isDesktopReachable)

        let base = Date()
        XCTAssertTrue(sessionsVM.isDesktopUnreachable(now: base), "no heartbeat ever seen → banner")

        try await fx.transport.save([
            try CloudRecordFactory.record(for: HeartbeatPayload(updatedAt: base, appVersion: "1.0.0"), modifiedAt: base)
        ])
        _ = try await feed.pollOnce()
        XCTAssertFalse(
            sessionsVM.isDesktopUnreachable(now: base.addingTimeInterval(11 * 60)),
            "heartbeat 11 min old → reachable"
        )
        XCTAssertTrue(
            sessionsVM.isDesktopUnreachable(now: base.addingTimeInterval(13 * 60)),
            "heartbeat older than 12 min → banner"
        )

        // (b) First-chunk wait → inline banner (frozen assembler clock pins
        // the reply row's createdAt).
        let sendInstant = Date(timeIntervalSince1970: 1_783_000_000)
        let frozen = try makeFixture(now: { sendInstant })
        let vm = makeThreadVM(frozen)
        vm.draft = "Anyone home?"
        await vm.send()
        try await poll { vm.messages.count == 2 }
        let reply = try XCTUnwrap(vm.messages.last)

        XCTAssertFalse(vm.showsWaitingBanner(for: reply, now: sendInstant.addingTimeInterval(44)))
        XCTAssertTrue(vm.showsWaitingBanner(for: reply, now: sendInstant.addingTimeInterval(46)))
        // The user's own turn never carries the banner, however long we wait.
        XCTAssertFalse(
            vm.showsWaitingBanner(for: try XCTUnwrap(vm.messages.first), now: sendInstant.addingTimeInterval(600))
        )

        // First chunk landed → the wait is over (even while incomplete).
        try await frozen.assembler.ingest(
            ChatChunkPayload(
                sessionID: try XCTUnwrap(vm.sessionID), messageID: reply.id,
                seq: 0, text: "Here", done: false
            )
        )
        try await poll { vm.messages.last?.text == "Here" }
        XCTAssertFalse(
            vm.showsWaitingBanner(for: try XCTUnwrap(vm.messages.last), now: sendInstant.addingTimeInterval(600))
        )
    }

    // MARK: - AppEnvironment wiring (feed → assembler)

    /// The Task 7 wiring itself: `AppEnvironment` hands the assembler to
    /// `RelayFeed`, so the DEBUG demo exchange's streamed chunks — dropped
    /// with a warning before this task — now assemble into a completed
    /// assistant reply through the feed's own poll loop.
    func testEnvironmentWiresAssemblerIntoFeedViaDemoExchange() async throws {
        let env = AppEnvironment(transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath())

        try await poll(timeout: 10, {
            guard let session = (try? env.store.chatSessions())?.first,
                  let reply = (try? env.store.chatMessages(inSession: session.id))?.last
            else { return false }
            return reply.role == .assistant && reply.isComplete && !reply.text.isEmpty && !reply.isError
        }, "demo chat exchange never assembled — is the assembler wired into the feed?")
    }
}
