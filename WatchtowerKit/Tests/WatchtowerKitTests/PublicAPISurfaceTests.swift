/// Plain-import compile gate for the iOS app's public WatchtowerKit surface.
///
/// NO @testable. Every symbol referenced here must be public.
/// If this file fails to compile, the iOS app would also fail to build.
///
/// Coverage: transport protocols, relay entry points, replica-relevant models.
/// Intentionally NOT exhaustive — it exercises what list UIs and relay
/// round-trips actually use, not every helper on every type.
///
/// GRDB is imported the way the iOS app imports it — alongside the Kit, for
/// Row (payload building) and ValueObservation over ReplicaStore.reader.
import GRDB
import WatchtowerKit
import XCTest

final class PublicAPISurfaceTests: XCTestCase {

    // MARK: - CloudSyncTransport protocol + InMemoryCloudTransport

    func testCloudSyncTransportViaInMemory() async throws {
        // InMemoryCloudTransport is the iOS app's test double for CloudKitTransport.
        // Construct through the protocol seam to prove the conformance is public.
        let transport: any CloudSyncTransport = InMemoryCloudTransport()

        let record = CloudRecord(
            recordName: "target-1",
            zone: .data,
            kind: "target",
            modifiedAt: Date(),
            payload: Data()
        )
        try await transport.save([record])
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.count, 1)
        XCTAssertEqual(batch.changed[0].recordName, record.recordName)
        // Plan 6: CloudRecord.notifyLevel is public — the Task 4 hydrator
        // hook reads it off applied batches.
        XCTAssertNil(batch.changed[0].notifyLevel)
        XCTAssertEqual(batch.newToken.value, 1)

        try await transport.delete(recordNames: ["target-1"], in: .data)
        let afterDelete = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(afterDelete.deletedRecordNames.contains("target-1"))
    }

    // MARK: - SliceRecord + SliceKind

    func testSliceRecordConstruction() {
        let record = SliceRecord(
            kind: .target,
            id: "42",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data("{}".utf8)
        )
        XCTAssertEqual(record.recordName, "target-42")
        XCTAssertEqual(record.kind, .target)
        XCTAssertEqual(record.id, "42")
        // Plan 6: notifyLevel is public (the Task 4 notification coordinator
        // reads it) and defaults to nil for the pre-Plan-6 initializer shape.
        XCTAssertNil(record.notifyLevel)
        let tagged = SliceRecord(
            kind: .inboxItem,
            id: "7",
            modifiedAt: Date(),
            payload: Data("{}".utf8),
            notifyLevel: "urgent"
        )
        XCTAssertEqual(tagged.notifyLevel, "urgent")
    }

    // MARK: - RelayCoder

    func testRelayCoderRoundTrip() throws {
        let action = ActionRequestPayload(
            id: "ios-test-1",
            kind: .targetDone,
            entityID: "99",
            params: [:],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try RelayCoder.makeEncoder().encode(action)
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: data)
        XCTAssertEqual(decoded.id, action.id)
        XCTAssertEqual(decoded.kind, action.kind)
        XCTAssertEqual(decoded.entityID, action.entityID)
    }

    // MARK: - CloudRecordFactory

    func testCloudRecordFactoryForSlice() {
        let slice = SliceRecord(kind: .inboxItem, id: "7", modifiedAt: Date(), payload: Data())
        let cloudRecord = CloudRecordFactory.record(for: slice)
        XCTAssertEqual(cloudRecord.recordName, "inbox_item-7")
        XCTAssertEqual(cloudRecord.zone, .data)
    }

    func testCloudRecordFactoryForRelay() throws {
        let action = ActionRequestPayload(
            id: "R1",
            kind: .inboxResolve,
            entityID: "5",
            params: [:],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let cloudRecord = try CloudRecordFactory.record(for: action, modifiedAt: action.createdAt)
        XCTAssertEqual(cloudRecord.recordName, "action-R1")
        XCTAssertEqual(cloudRecord.zone, .relay)
    }

    // MARK: - Target model fields (list UI)

    func testTargetPublicFields() {
        // Verify the fields list UIs read are publicly accessible.
        // Build via init(row:) is internal — use the public Codable init instead.
        // Just compile-check that the field names exist and have the expected types.
        let keyPath1: KeyPath<Target, String> = \.text
        let keyPath2: KeyPath<Target, String> = \.status
        let keyPath3: KeyPath<Target, String> = \.priority
        // The Tasks tab's priority badge (Task 9) — must stay public.
        let keyPath4: KeyPath<Target, String> = \.priorityColor
        // Suppress unused-variable warnings; the point is the compile, not the value.
        _ = keyPath1; _ = keyPath2; _ = keyPath3; _ = keyPath4
    }

    // MARK: - InboxItem model fields (feed UI)

    func testInboxItemPublicFields() {
        let keyPath1: KeyPath<InboxItem, String> = \.snippet
        let keyPath2: KeyPath<InboxItem, String> = \.status
        let keyPath3: KeyPath<InboxItem, Bool> = \.pinned
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - Track model fields (track list)

    func testTrackPublicFields() {
        let keyPath1: KeyPath<Track, String> = \.text
        let keyPath2: KeyPath<Track, String> = \.category
        let keyPath3: KeyPath<Track, String> = \.priority
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - Briefing model fields

    func testBriefingPublicFields() {
        let keyPath1: KeyPath<Briefing, String> = \.date
        let keyPath2: KeyPath<Briefing, Bool> = \.isRead
        _ = keyPath1; _ = keyPath2
    }

    // MARK: - CalendarEvent model fields

    func testCalendarEventPublicFields() {
        let keyPath1: KeyPath<CalendarEvent, String> = \.title
        let keyPath2: KeyPath<CalendarEvent, String> = \.startTime
        let keyPath3: KeyPath<CalendarEvent, Bool> = \.isAllDay
        _ = keyPath1; _ = keyPath2; _ = keyPath3
    }

    // MARK: - CloudKit entitlement probe (the AppEnvironment transport swap)

    func testEntitlementProbeIsPublicAndFalseInUnsignedHost() {
        // The SwiftPM test host is NOT signed with the Watchtower iCloud
        // container — the exact reality of every CI/sim run. The probe must
        // report that honestly (false), which is what keeps unsigned builds
        // on the InMemory+DemoSeed path instead of crashing into CloudKit.
        XCTAssertFalse(CloudKitTransport.entitlementPresent())
        // The default containerID is the frozen WatchtowerCloud one; an
        // explicit pass-through must behave identically.
        XCTAssertFalse(CloudKitTransport.entitlementPresent(containerID: WatchtowerCloud.containerID))
    }

    // MARK: - TransportStore public surface

    func testTransportStorePublicInit() throws {
        // Only init(path:) and inMemory() are public — the adapter internals are internal.
        let store = try TransportStore.inMemory()
        // wipe(), compactEvents(in:keepSince:) and sweepEvents(in:olderThan:upTo:)
        // stay public (reset path + CompactingTransport + SweepingTransport).
        try store.wipe()
        try store.compactEvents(in: .data, keepSince: CloudChangeToken(value: 0))
        _ = try store.sweepEvents(in: .relay, olderThan: .distantPast, upTo: CloudChangeToken(value: 0))
        // changes(in:since:) stays public (Task 4 hydrator may read the store directly,
        // though the transport wraps it — keeping it public avoids sealing the door
        // on that access pattern before Task 4 decides).
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
    }

    // MARK: - ReplicaStore + ReplicaHydrator (the iOS replica read path)

    func testReplicaStoreAndHydratorSurface() async throws {
        let store = try ReplicaStore.inMemory()
        let payload = try RowPayloadCoder.payload(from: Row(["id": 1, "text": "surface"]))
        let record = CloudRecord(
            recordName: SliceKind.target.recordName(id: "1"),
            zone: .data,
            kind: SliceKind.target.rawValue,
            modifiedAt: Date(),
            payload: payload
        )
        let transport: any CloudSyncTransport = InMemoryCloudTransport()
        try await transport.save([record])

        let hydrator = ReplicaHydrator(transport: transport, store: store)
        let result = try await hydrator.hydrateOnce()
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.deleted, 0)

        // Typed reads: exactly what the iOS list UIs call.
        let targets = try store.fetchAll(Target.self, kind: .target)
        XCTAssertEqual(targets.first?.text, "surface")
        XCTAssertEqual(store.corruptCount(), 0)
        XCTAssertNotNil(try store.storedToken())

        // reader is the ValueObservation entry point for the UI, and
        // fetchAll(_:kind:from:) is the overload the app's ReplicaObserver
        // calls inside its tracking closure (the closure's own db) — both must
        // be public for the app to build.
        let count = try await store.reader.read { db -> Int in
            _ = try store.fetchAll(Target.self, kind: .target, from: db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0
        }
        XCTAssertEqual(count, 1)

        await hydrator.start(interval: .seconds(60))
        await hydrator.stop()

        // Plan 6 Task 4 surface: the post-batch hook the app's
        // NotificationCoordinator consumes, its payload's fields, and the
        // alert-dedup watermark accessors — all called from the app target.
        let hook: @Sendable ([AppliedSliceRecord]) -> Void = { records in
            for applied in records {
                _ = applied.recordName
                _ = applied.kind
                _ = applied.notifyLevel
                _ = applied.modifiedAt
            }
        }
        let hooked = ReplicaHydrator(
            transport: transport,
            store: store,
            pull: nil,
            onRecordsApplied: hook
        )
        _ = try await hooked.hydrateOnce()
        XCTAssertNil(try store.lastAlertedWatermark())
        try store.setLastAlertedWatermark(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(try store.lastAlertedWatermark())
    }

    // MARK: - ActionOutbox + PendingAction (the iOS action-producer path)

    func testActionOutboxAndPendingOverlaySurface() async throws {
        let store = try ReplicaStore.inMemory()
        let transport: any CloudSyncTransport = InMemoryCloudTransport()
        let outbox = ActionOutbox(transport: transport, store: store)

        // enqueue + snoozeParams: what the app's swipe actions call.
        let id = try await outbox.enqueue(
            kind: .targetSnooze,
            entityRecordName: "target-42",
            params: ActionOutbox.snoozeParams(until: Date())
        )

        // Overlay reads: full list, per-entity join, and the from-db overload
        // the app's ValueObservation tracking closures must use.
        let row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.action.kind, .targetSnooze)
        XCTAssertEqual(row.entityRecordName, "target-42")
        XCTAssertEqual(try store.pendingActions(forEntity: "target-42").count, 1)
        let observedCount = try await store.reader.read { db in
            try store.pendingActions(from: db).count
        }
        XCTAssertEqual(observedCount, 1)

        // applyEcho: app-target tests drive echoes directly (Plan 4 Task 6).
        var echo = row.action
        echo.status = .failed
        echo.errorMessage = "surface"
        try await outbox.applyEcho(echo)

        // sweepSilentPending + removePendingAction: daily sweep + the
        // "Dismiss" affordance on failed rows.
        let swept = try await outbox.sweepSilentPending()
        XCTAssertTrue(swept.isEmpty)
        try store.removePendingAction(id: id)
        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    // MARK: - RelayFeed + ChatChunkAssembling (the iOS relay-consumer path)

    /// The app never sees chunks directly — but Task 5's ChatAssembler must be
    /// able to conform from outside the Kit's internals, so the seam is public.
    private actor SurfaceAssembler: ChatChunkAssembling {
        func ingest(_ chunk: ChatChunkPayload) async throws {}
    }

    func testRelayFeedSurface() async throws {
        let store = try ReplicaStore.inMemory()
        let transport: any CloudSyncTransport = InMemoryCloudTransport()
        let outbox = ActionOutbox(transport: transport, store: store)
        let feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            assembler: SurfaceAssembler(),
            pull: nil,
            onActionApplied: nil
        )

        // pollOnce is what AppEnvironment.refresh calls alongside hydrateOnce.
        let heartbeat = HeartbeatPayload(updatedAt: Date(), appVersion: "1.0.0")
        try await transport.save([try CloudRecordFactory.record(for: heartbeat, modifiedAt: heartbeat.updatedAt)])
        let result = try await feed.pollOnce()
        XCTAssertEqual(result.echoes, 0)
        XCTAssertEqual(result.chunks, 0)

        // Liveness reads: the view models' reachability banner.
        XCTAssertTrue(feed.isDesktopReachable(now: heartbeat.updatedAt))
        XCTAssertEqual(RelayFeed.heartbeatStaleAfter, .seconds(12 * 60))
        XCTAssertNotNil(try store.heartbeatAge(now: heartbeat.updatedAt))

        await feed.start(interval: .seconds(60))
        await feed.stop()
    }

    // MARK: - ChatAssembler + chat replica (the iOS chat path)

    func testChatAssemblerAndChatReplicaSurface() async throws {
        let store = try ReplicaStore.inMemory()
        let transport: any CloudSyncTransport = InMemoryCloudTransport()
        let assembler = ChatAssembler(transport: transport, store: store)

        // send + firstChunkPending + the liveness threshold: the Task 7 VM's calls.
        let (sessionID, messageID) = try await assembler.send(text: "hello from the surface", sessionID: nil)
        var pending = await assembler.firstChunkPending(messageID: messageID)
        XCTAssertTrue(pending)
        XCTAssertEqual(ChatAssembler.unreachableAfter, .seconds(45))

        // ingest through the ChatChunkAssembling seam RelayFeed consumes.
        let assembling: any ChatChunkAssembling = assembler
        try await assembling.ingest(
            ChatChunkPayload(sessionID: sessionID, messageID: messageID, seq: 0, text: "Hi!", done: true)
        )
        pending = await assembler.firstChunkPending(messageID: messageID)
        XCTAssertFalse(pending)

        // Chat reads: sessions list + one thread, with the public model fields
        // the chat UI renders.
        let session = try XCTUnwrap(store.chatSessions().first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.title, "hello from the surface")
        XCTAssertLessThanOrEqual(session.createdAt, session.updatedAt)
        let messages = try store.chatMessages(inSession: sessionID)
        XCTAssertEqual(messages.map(\.role), [ChatMessage.Role.user, .assistant])
        XCTAssertEqual(messages.first?.text, "hello from the surface")
        XCTAssertEqual(messages.last?.id, messageID)
        XCTAssertEqual(messages.last?.text, "Hi!")
        XCTAssertEqual(messages.last?.isComplete, true)
        XCTAssertEqual(messages.last?.isError, false)

        // Plan 5 Task 7 surface: the per-session direct-mode opt-in flag the
        // thread VM routes on, and its only write path.
        XCTAssertFalse(session.directMode)
        try store.setDirectMode(sessionID: sessionID, enabled: true)
        XCTAssertEqual(try store.chatSessions().first?.directMode, true)
        try store.setDirectMode(sessionID: sessionID, enabled: false)

        // The from-db overloads the app's ValueObservation tracking closures
        // must use (same reentrancy rule as fetchAll(_:kind:from:)).
        let counts = try await store.reader.read { db in
            (sessions: try store.chatSessions(from: db).count,
             messages: try store.chatMessages(inSession: sessionID, from: db).count)
        }
        XCTAssertEqual(counts.sessions, 1)
        XCTAssertEqual(counts.messages, 2)

        // Plan 5 surface: the route parameter with both SendRoute cases, and
        // the empty-text guard's public error (the VM catches it by case).
        let relayRoute: SendRoute = .relay
        _ = try await assembler.send(text: "explicit relay route", sessionID: sessionID, route: relayRoute)
        _ = try await assembler.send(text: "offline turn", sessionID: sessionID, route: .localOnly)
        do {
            _ = try await assembler.send(text: "   ", sessionID: sessionID, route: .localOnly)
            XCTFail("expected ChatSendError.emptyText")
        } catch ChatSendError.emptyText {
            XCTAssertEqual(ChatSendError.emptyText, ChatSendError.emptyText) // Equatable is public API
        }
    }

    // MARK: - MobileAgentBackend + both backends (Plan 5 BYOK agent)

    /// The app injects its own scripted client in tests — the seam must be
    /// conformable from outside the Kit.
    private struct SurfaceClient: AnthropicStreaming {
        func streamMessage(request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testMobileAgentBackendSurface() async throws {
        let store = try ReplicaStore.inMemory()
        let transport: any CloudSyncTransport = InMemoryCloudTransport()
        let assembler = ChatAssembler(transport: transport, store: store)

        // RelayAgentBackend through the protocol existential — the exact shape
        // ChatThreadViewModel holds (Task 7).
        let relay: any MobileAgentBackend = RelayAgentBackend(assembler: assembler)
        let (sessionID, messageID) = try await relay.sendTurn(text: "surface relay turn", sessionID: nil)
        XCTAssertFalse(sessionID.isEmpty)
        XCTAssertFalse(messageID.isEmpty)

        // DirectAPIAgent constructible from public API alone, including the
        // injectable client factory and clock; missingKey is public and
        // catchable by case.
        let outbox = ActionOutbox(transport: transport, store: store)
        let toolbox = ReplicaToolbox(store: store, outbox: outbox)
        let direct: any MobileAgentBackend = DirectAPIAgent(
            assembler: assembler,
            store: store,
            toolbox: toolbox,
            apiKey: { nil },
            model: { .sonnet5 },
            clientFactory: { _ in SurfaceClient() }
        )
        do {
            _ = try await direct.sendTurn(text: "no key configured", sessionID: nil)
            XCTFail("expected DirectAPIAgentError.missingKey")
        } catch DirectAPIAgentError.missingKey {}

        // The static system prompt is public (Settings may preview it) and
        // errors render readable copy via LocalizedError.
        XCTAssertFalse(MobileSystemPrompt.build().isEmpty)
        XCTAssertNotNil(DirectAPIAgentError.missingKey.errorDescription)
        XCTAssertNotNil(AnthropicClientError.invalidKey.errorDescription)
        XCTAssertNotNil(ChatSendError.emptyText.errorDescription)
    }

    // MARK: - ReplicaToolbox (Plan 5 BYOK agent tools)

    func testReplicaToolboxSurface() async throws {
        // Constructible from public API alone (default `now` clock), tool
        // definitions readable as APITool, execute callable without throwing.
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store)
        let toolbox = ReplicaToolbox(store: store, outbox: outbox)

        XCTAssertEqual(toolbox.tools.count, 12)
        let tool: APITool? = toolbox.tools.first
        XCTAssertEqual(tool?.name, "list_targets")

        let result = await toolbox.execute(name: "list_targets", inputJSON: Data())
        XCTAssertEqual(result, "[]")
    }
}
