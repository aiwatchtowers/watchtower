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

    /// Recording turn-sender: pins WHICH backend the VM routed a send
    /// through. Built over an assembler it delegates to the real `.localOnly`
    /// send (rows land in the store, sessions get minted); standalone it
    /// returns canned ids without touching anything.
    private final class RecordingBackend: MobileAgentBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(text: String, sessionID: String?)] = []
        private let assembler: ChatAssembler?

        init(assembler: ChatAssembler? = nil) {
            self.assembler = assembler
        }

        var calls: [(text: String, sessionID: String?)] {
            lock.withLock { recorded }
        }

        func sendTurn(text: String, sessionID: String?) async throws -> (sessionID: String, messageID: String) {
            lock.withLock { recorded.append((text, sessionID)) }
            if let assembler {
                return try await assembler.send(text: text, sessionID: sessionID, route: .localOnly)
            }
            return (sessionID ?? "minted-session", "minted-message")
        }
    }

    /// A started thread VM with a fixed reachability answer (banner math has
    /// its own dedicated test below). Default backends mirror production
    /// shape: a REAL relay over the fixture's assembler, an inert direct
    /// backend (keyless VMs must never touch it).
    private func makeThreadVM(
        _ fx: Fixture,
        sessionID: String? = nil,
        reachable: Bool = true,
        hasKey: Bool = false,
        direct: (any MobileAgentBackend)? = nil,
        relay: (any MobileAgentBackend)? = nil
    ) -> ChatThreadViewModel {
        let vm = ChatThreadViewModel()
        vm.start(
            store: fx.store,
            direct: direct ?? RecordingBackend(),
            relay: relay ?? RelayAgentBackend(assembler: fx.assembler),
            hasKey: { hasKey },
            isReachable: { _ in reachable },
            sessionID: sessionID
        )
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

    // MARK: - Mid-stream scroll following (Task 7 review Minor 3)

    /// The thread view follows STREAMING growth, not just new rows: its
    /// scroll trigger (`scrollKey`) must move when a chunk grows the last
    /// message's text in place — `messages.count` is unchanged there — and
    /// keep moving on every appended row.
    func testScrollKeyMovesOnMidStreamGrowthAndOnAppend() async throws {
        let fx = try makeFixture()
        let vm = makeThreadVM(fx)
        vm.draft = "Follow the stream"
        await vm.send()
        try await poll { vm.messages.count == 2 }
        let sessionID = try XCTUnwrap(vm.sessionID)
        let replyID = try XCTUnwrap(vm.messages.last?.id)
        let keyAfterSend = vm.scrollKey

        try await fx.assembler.ingest(
            ChatChunkPayload(sessionID: sessionID, messageID: replyID, seq: 0, text: "chunk one", done: false)
        )
        try await poll { vm.messages.last?.text == "chunk one" }
        XCTAssertEqual(vm.messages.count, 2, "chunk growth is in place — no new row")
        let keyMidStream = vm.scrollKey
        XCTAssertNotEqual(keyMidStream, keyAfterSend, "in-place text growth must move the scroll key")

        try await fx.assembler.ingest(
            ChatChunkPayload(sessionID: sessionID, messageID: replyID, seq: 1, text: " and two", done: true)
        )
        try await poll { vm.messages.last?.isComplete == true }
        XCTAssertNotEqual(vm.scrollKey, keyMidStream, "the final chunk still grows the text")

        vm.draft = "Another turn"
        await vm.send()
        try await poll { vm.messages.count == 4 }
        XCTAssertNotEqual(vm.scrollKey, keyMidStream, "appended rows keep moving the key")
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

    /// The per-message waiting-hint matrix (Plan 6 Task 6): past
    /// `ChatAssembler.unreachableAfter` a RELAY thread shows the
    /// Mac-unreachable banner exactly as before, a DIRECT thread shows the
    /// neutral "Still thinking…" hint instead (the phone answers itself —
    /// Mac framing would mislead), and below the threshold neither route
    /// shows anything.
    func testWaitingHintMatrixRelayVsDirect() async throws {
        let sendInstant = Date(timeIntervalSince1970: 1_783_000_000)
        let fx = try makeFixture(now: { sendInstant })
        let vm = makeThreadVM(fx, hasKey: true)
        vm.draft = "Take your time"
        await vm.send()
        try await poll { vm.messages.count == 2 }
        let reply = try XCTUnwrap(vm.messages.last)

        // Relay route: below the threshold nothing, past it the Mac banner.
        XCTAssertEqual(vm.waitingHint(for: reply, now: sendInstant.addingTimeInterval(44)), .none)
        XCTAssertEqual(vm.waitingHint(for: reply, now: sendInstant.addingTimeInterval(46)), .macUnreachable)

        // Direct route: the same wait turns into the neutral hint — never
        // the Mac-unreachable framing.
        vm.setDirectMode(true)
        XCTAssertEqual(vm.waitingHint(for: reply, now: sendInstant.addingTimeInterval(44)), .none)
        XCTAssertEqual(vm.waitingHint(for: reply, now: sendInstant.addingTimeInterval(46)), .stillThinking)

        // The user's own turn never hints, however long we wait.
        XCTAssertEqual(
            vm.waitingHint(for: try XCTUnwrap(vm.messages.first), now: sendInstant.addingTimeInterval(600)),
            .none
        )

        // First chunk landed → the wait is over on both routes.
        try await fx.assembler.ingest(
            ChatChunkPayload(
                sessionID: try XCTUnwrap(vm.sessionID), messageID: reply.id,
                seq: 0, text: "Here", done: false
            )
        )
        try await poll { vm.messages.last?.text == "Here" }
        XCTAssertEqual(
            vm.waitingHint(for: try XCTUnwrap(vm.messages.last), now: sendInstant.addingTimeInterval(600)),
            .none
        )
    }

    /// The sessions-list badge (Plan 6 Task 6) is driven by
    /// `ChatSession.directMode`: the row data the `bolt.fill` glyph reads
    /// must surface the flag through the sessions observation — and follow
    /// it back down when the user returns to the relay.
    func testSessionsListSurfacesDirectModeForBadge() async throws {
        let fx = try makeFixture()
        let (directID, _) = try await fx.assembler.send(text: "direct thread", sessionID: nil)
        let (relayID, _) = try await fx.assembler.send(text: "relay thread", sessionID: nil)
        try fx.store.setDirectMode(sessionID: directID, enabled: true)

        let vm = ChatSessionsViewModel()
        vm.start(store: fx.store, isReachable: { _ in true })
        try await poll { vm.sessions.count == 2 }

        XCTAssertEqual(vm.sessions.first { $0.id == directID }?.directMode, true)
        XCTAssertEqual(
            vm.sessions.first { $0.id == relayID }?.directMode, false,
            "relay sessions must never wear the badge"
        )

        // "Back to Mac relay" clears the badge through the same observation.
        try fx.store.setDirectMode(sessionID: directID, enabled: false)
        try await poll { vm.sessions.first { $0.id == directID }?.directMode == false }
    }

    // MARK: - Direct-API opt-in (Plan 5 Task 7)

    /// A direct-flagged session routes send() through the DIRECT backend and
    /// leaves the relay untouched — and the persisted flag survives VM
    /// re-creation (navigate away and back) because start() restores it.
    func testDirectModeSessionRoutesSendThroughDirectBackendOnly() async throws {
        let fx = try makeFixture()
        let (sessionID, _) = try await fx.assembler.send(text: "opening turn", sessionID: nil)
        try fx.store.setDirectMode(sessionID: sessionID, enabled: true)

        let direct = RecordingBackend()
        let relay = RecordingBackend()
        let vm = makeThreadVM(fx, sessionID: sessionID, hasKey: true, direct: direct, relay: relay)
        XCTAssertTrue(vm.directMode, "start() must restore the persisted opt-in")

        vm.draft = "route me directly"
        await vm.send()

        XCTAssertEqual(direct.calls.count, 1)
        XCTAssertEqual(direct.calls.first?.text, "route me directly")
        XCTAssertEqual(direct.calls.first?.sessionID, sessionID)
        XCTAssertTrue(relay.calls.isEmpty, "a direct session must never touch the relay backend")
        XCTAssertEqual(vm.draft, "", "a successful direct send clears the draft")
    }

    /// A throwing backend (the missingKey shape: key removed after opt-in)
    /// must surface the send-error banner and KEEP the draft — the spec's
    /// "sendTurn throws → existing error banner, draft kept" contract.
    func testBackendThrowSurfacesErrorBannerAndKeepsDraft() async throws {
        final class ThrowingBackend: MobileAgentBackend, @unchecked Sendable {
            func sendTurn(text: String, sessionID: String?) async throws -> (sessionID: String, messageID: String) {
                throw DirectAPIAgentError.missingKey
            }
        }
        let fx = try makeFixture()
        let (sessionID, _) = try await fx.assembler.send(text: "opening turn", sessionID: nil)
        try fx.store.setDirectMode(sessionID: sessionID, enabled: true)

        let relay = RecordingBackend()
        let vm = makeThreadVM(fx, sessionID: sessionID, hasKey: false, direct: ThrowingBackend(), relay: relay)

        vm.draft = "doomed question"
        await vm.send()

        XCTAssertNotNil(vm.sendErrorMessage, "a backend throw must surface the error banner")
        XCTAssertEqual(vm.draft, "doomed question", "a failed send must keep the draft")
        XCTAssertTrue(relay.calls.isEmpty, "a direct-flagged session must not fall back silently")
        let messages = try fx.store.chatMessages(inSession: sessionID)
        XCTAssertEqual(messages.count, 2, "the failed turn must not persist rows beyond the opener")
    }

    /// The inverse: no opt-in → relay backend only, direct untouched.
    func testRelaySessionRoutesSendThroughRelayBackendOnly() async throws {
        let fx = try makeFixture()
        let (sessionID, _) = try await fx.assembler.send(text: "opening turn", sessionID: nil)

        let direct = RecordingBackend()
        let relay = RecordingBackend()
        let vm = makeThreadVM(fx, sessionID: sessionID, hasKey: true, direct: direct, relay: relay)
        XCTAssertFalse(vm.directMode)

        vm.draft = "stay on the relay"
        await vm.send()

        XCTAssertEqual(relay.calls.count, 1)
        XCTAssertEqual(relay.calls.first?.text, "stay on the relay")
        XCTAssertTrue(direct.calls.isEmpty, "no opt-in → the direct backend must stay untouched")
    }

    /// The banner affordance matrix — a pure state function (Decision 7).
    func testDirectOptInStateMatrix() {
        XCTAssertEqual(DirectOptInState(hasKey: false, directMode: false), .needsKey)
        XCTAssertEqual(DirectOptInState(hasKey: true, directMode: false), .offerDirect)
        XCTAssertEqual(DirectOptInState(hasKey: true, directMode: true), .directActive)
        // Key removed AFTER opt-in: still directActive — the toolbar chip's
        // "Back to Mac relay" must stay reachable, and a direct send without
        // a key fails into the send-error banner with the draft kept.
        XCTAssertEqual(DirectOptInState(hasKey: false, directMode: true), .directActive)
    }

    /// Dialog acceptance from the banner flips the flag AT THE STORE and does
    /// NOT auto-resend: the draft stays in the compose field (the send-throw
    /// contract keeps it there) and the user re-taps send themselves.
    func testBannerConfirmFlipsFlagWithoutAutoResend() async throws {
        let fx = try makeFixture()
        let direct = RecordingBackend()
        let relay = RecordingBackend(assembler: fx.assembler)
        // No key at first send → no pre-send offer; the session mints on the relay.
        let vm = makeThreadVM(fx, reachable: false, hasKey: false, direct: direct, relay: relay)
        vm.draft = "sent over the relay"
        await vm.send()
        let sessionID = try XCTUnwrap(vm.sessionID)
        XCTAssertEqual(try fx.store.chatSessions().first?.directMode, false)

        // Banner "Answer directly" → dialog → confirm.
        vm.draft = "typed before confirming"
        vm.offerDirect(.banner)
        XCTAssertEqual(vm.directOfferContext, .banner)
        await vm.confirmDirectOffer(.banner)

        XCTAssertNil(vm.directOfferContext)
        XCTAssertTrue(vm.directMode)
        XCTAssertEqual(
            try fx.store.chatSessions().first { $0.id == sessionID }?.directMode, true,
            "acceptance must persist the flag on THAT session"
        )
        XCTAssertEqual(vm.draft, "typed before confirming", "confirm must NOT auto-resend — the user re-taps")
        XCTAssertEqual(relay.calls.count, 1)
        XCTAssertTrue(direct.calls.isEmpty)

        // The user re-taps send → the DIRECT backend now carries the turn.
        await vm.send()
        XCTAssertEqual(direct.calls.count, 1)
        XCTAssertEqual(direct.calls.first?.text, "typed before confirming")
        XCTAssertEqual(relay.calls.count, 1)

        // Toolbar "Back to Mac relay" writes through to the store too.
        vm.setDirectMode(false)
        XCTAssertFalse(vm.directMode)
        XCTAssertEqual(try fx.store.chatSessions().first { $0.id == sessionID }?.directMode, false)
    }

    /// New chat + key + unreachable Mac: the send tap is held behind the same
    /// dialog; confirming routes the FIRST send through the direct backend
    /// and flags the session it minted.
    func testNewSessionOfferConfirmRoutesFirstSendDirectAndFlagsMintedSession() async throws {
        let fx = try makeFixture()
        let direct = RecordingBackend(assembler: fx.assembler)
        let relay = RecordingBackend()
        let vm = makeThreadVM(fx, reachable: false, hasKey: true, direct: direct, relay: relay)

        vm.draft = "offline question"
        await vm.send()

        // Held back: nothing may ship before the user chooses.
        XCTAssertEqual(vm.directOfferContext, .firstSend)
        XCTAssertTrue(direct.calls.isEmpty)
        XCTAssertTrue(relay.calls.isEmpty)
        XCTAssertEqual(vm.draft, "offline question", "the held-back draft stays in the compose field")

        await vm.confirmDirectOffer(.firstSend)

        let call = try XCTUnwrap(direct.calls.first)
        XCTAssertEqual(call.text, "offline question")
        XCTAssertNil(call.sessionID, "the dialog decides the FIRST send — before any session exists")
        XCTAssertTrue(relay.calls.isEmpty)
        let sessionID = try XCTUnwrap(vm.sessionID)
        XCTAssertEqual(
            try fx.store.chatSessions().first { $0.id == sessionID }?.directMode, true,
            "the minted session must be flagged the moment its id exists"
        )
        XCTAssertTrue(vm.directMode)
        XCTAssertEqual(vm.draft, "")
    }

    /// Declining the new-chat offer sends via the relay as today, and the
    /// resolved session stops re-asking.
    func testNewSessionOfferDeclineRoutesRelayAndDoesNotReask() async throws {
        let fx = try makeFixture()
        let direct = RecordingBackend()
        let relay = RecordingBackend(assembler: fx.assembler)
        let vm = makeThreadVM(fx, reachable: false, hasKey: true, direct: direct, relay: relay)

        vm.draft = "keep it on the Mac"
        await vm.send()
        XCTAssertEqual(vm.directOfferContext, .firstSend)

        await vm.declineDirectOffer(.firstSend)

        XCTAssertEqual(relay.calls.count, 1)
        XCTAssertEqual(relay.calls.first?.text, "keep it on the Mac")
        XCTAssertTrue(direct.calls.isEmpty)
        XCTAssertFalse(vm.directMode)
        let sessionID = try XCTUnwrap(vm.sessionID)
        XCTAssertEqual(try fx.store.chatSessions().first { $0.id == sessionID }?.directMode, false)

        // Follow-up sends go relay WITHOUT re-asking (the session exists now).
        vm.draft = "follow-up"
        await vm.send()
        XCTAssertNil(vm.directOfferContext)
        XCTAssertEqual(relay.calls.count, 2)
        XCTAssertTrue(direct.calls.isEmpty)
    }

    /// The pre-first-send ask fires ONLY for key + unreachable on a new chat:
    /// a reachable Mac and a keyless phone both send via the relay
    /// immediately, exactly as before this task.
    func testFirstSendOfferRequiresKeyAndUnreachable() async throws {
        // Reachable + key → no dialog, straight to the relay.
        let reachableFx = try makeFixture()
        let reachableRelay = RecordingBackend(assembler: reachableFx.assembler)
        let reachableVM = makeThreadVM(reachableFx, reachable: true, hasKey: true, relay: reachableRelay)
        reachableVM.draft = "mac is right here"
        await reachableVM.send()
        XCTAssertNil(reachableVM.directOfferContext)
        XCTAssertEqual(reachableRelay.calls.count, 1)

        // Unreachable + NO key → no dialog either (the banner routes to
        // Settings instead); relay as today.
        let keylessFx = try makeFixture()
        let keylessRelay = RecordingBackend(assembler: keylessFx.assembler)
        let keylessVM = makeThreadVM(keylessFx, reachable: false, hasKey: false, relay: keylessRelay)
        keylessVM.draft = "no key on this phone"
        await keylessVM.send()
        XCTAssertNil(keylessVM.directOfferContext)
        XCTAssertEqual(keylessRelay.calls.count, 1)
    }

    // MARK: - AppEnvironment wiring (feed → assembler)

    /// The Task 7 wiring itself: `AppEnvironment` hands the assembler to
    /// `RelayFeed`, so the DEBUG demo exchange's streamed chunks — dropped
    /// with a warning before this task — now assemble into a completed
    /// assistant reply through the feed's own poll loop.
    func testEnvironmentWiresAssemblerIntoFeedViaDemoExchange() async throws {
        let env = try AppEnvironment(transport: InMemoryCloudTransport(), replicaPath: makeReplicaPath())

        try await poll(timeout: 10, {
            guard let session = (try? env.store.chatSessions())?.first,
                  let reply = (try? env.store.chatMessages(inSession: session.id))?.last
            else { return false }
            return reply.role == .assistant && reply.isComplete && !reply.text.isEmpty && !reply.isError
        }, "demo chat exchange never assembled — is the assembler wired into the feed?")
    }
}
