import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Board writes from the phone (spec §5.2, §6.3, §9, §13 B5): the status
/// and priority pickers, the conflict prompt, the comment composer, the new
/// target sheet and the pending rows, over the demo board and a real outbox.
@MainActor
final class BoardWriteWiringTests: XCTestCase {
    private let now = Date()

    private struct Fixture {
        let store: ReplicaStore
        let outbox: ActionOutbox
        let writer: BoardWriter
    }

    private func makeFixture() throws -> Fixture {
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: DemoSeed.device.deviceID)
        return Fixture(store: store, outbox: outbox, writer: BoardWriter.sending(through: outbox, store: store))
    }

    /// The demo snapshot with the store's overlay rows, as the replica model
    /// reads them.
    private func snapshot(_ store: ReplicaStore, heartbeatAge: TimeInterval? = nil) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.pending = try store.pendingActions()
        if let heartbeatAge {
            let at = now.addingTimeInterval(-heartbeatAge)
            snapshot.heartbeat = HeartbeatPayload(
                updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
                lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
                enabledAt: at, ownerUser: "_user", sharing: .none
            )
        }
        return snapshot
    }

    private func detail(_ id: Int64, _ snapshot: WorkbenchReplicaSnapshot) throws -> BoardTargetDetailModel {
        try XCTUnwrap(BoardTargetDetailModel(targetID: id, snapshot: snapshot, now: now))
    }

    private func target(_ id: Int64) throws -> WorkbenchTarget {
        try XCTUnwrap(try demoSnapshot(now: now).targets.first { $0.id == id })
    }

    /// Flips the only overlay row to a failed echo.
    private func fail(
        _ fixture: Fixture, reason: ActionReason?, result: [String: JSONValue]? = nil, message: String?
    ) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = .failed
        echo.reason = reason
        echo.result = result
        echo.errorMessage = message
        try await fixture.outbox.applyEcho(echo)
    }

    // MARK: - Groups

    func testAGroupsStatusPickerIsDisabledWithItsCaption() throws {
        let group = try detail(400, try snapshot(try ReplicaStore.inMemory()))
        XCTAssertFalse(group.status.isEnabled)
        XCTAssertEqual(group.status.caption, "A group's status follows its sub-tasks")
        XCTAssertTrue(group.priority.isEnabled, "the hub allows a group's priority")

        let leaf = try detail(415, try snapshot(try ReplicaStore.inMemory()))
        XCTAssertTrue(leaf.status.isEnabled)
        XCTAssertNil(leaf.status.caption)
        XCTAssertEqual(leaf.status.options, WorkbenchTargetStatus.editable)
        XCTAssertEqual(leaf.priority.options, [.high, .medium, .low])
    }

    func testAnArchivedTargetIsReadOnly() throws {
        let archived = try detail(417, try snapshot(try ReplicaStore.inMemory()))
        XCTAssertTrue(archived.isReadOnly)
        XCTAssertFalse(archived.status.isEnabled)
        XCTAssertFalse(archived.priority.isEnabled)
    }

    // MARK: - Status, priority and the conflict prompt

    func testAStatusChangeSendsTheShownStatusAsFrom() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))

        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .boardTargetStatus)
        XCTAssertEqual(row.entityRecordName, "workbench_target-415")
        XCTAssertEqual(row.action.entityID, "415")
        let params = try BoardTargetStatusParams(wireParams: row.action.params)
        XCTAssertEqual(params, BoardTargetStatusParams(workbenchID: DemoSeed.acmeID, status: .done, fromStatus: .inProgress))

        // While it is pending the picker shows the request and is locked.
        let pending = try detail(415, try snapshot(fixture.store))
        XCTAssertEqual(pending.status.selection, .done)
        XCTAssertFalse(pending.status.isEnabled)
        XCTAssertTrue(pending.priority.isEnabled, "only the pending field is locked")
    }

    func testPickingTheShownValueSendsNothing() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.inProgress, on: try target(415))
        try await fixture.writer.setPriority(.high, on: try target(415))
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    func testAConflictEchoOffersApplyAnywayAndYesSendsTheCurrentValueAsFrom() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))
        let failedID = try XCTUnwrap(fixture.store.pendingActions().first).id
        try await fail(fixture, reason: .conflict, result: ["current": .string("blocked")], message: "Changed on the Mac to blocked")

        let row = try XCTUnwrap(try detail(415, try snapshot(fixture.store)).writes.first)
        XCTAssertEqual(row.state, .conflict(prompt: "Changed on the Mac to Blocked — apply anyway?"))
        XCTAssertTrue(try detail(415, try snapshot(fixture.store)).status.isEnabled, "a failed row does not lock the picker")

        try await fixture.writer.applyAnyway(row)

        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.count, 1)
        let retry = try XCTUnwrap(rows.first)
        XCTAssertNotEqual(retry.id, failedID, "a new action, the failed row removed")
        XCTAssertEqual(retry.state, .pending)
        XCTAssertEqual(retry.entityRecordName, "workbench_target-415")
        let params = try BoardTargetStatusParams(wireParams: retry.action.params)
        XCTAssertEqual(params, BoardTargetStatusParams(workbenchID: DemoSeed.acmeID, status: .done, fromStatus: .blocked))
    }

    func testAPriorityConflictRetriesWithTheCurrentPriority() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setPriority(.low, on: try target(415))
        try await fail(fixture, reason: .conflict, result: ["current": .string("medium")], message: "Changed on the Mac to medium")

        let row = try XCTUnwrap(try detail(415, try snapshot(fixture.store)).writes.first)
        XCTAssertEqual(row.state, .conflict(prompt: "Changed on the Mac to Medium — apply anyway?"))
        try await fixture.writer.applyAnyway(row)

        let retry = try XCTUnwrap(fixture.store.pendingActions().first)
        let params = try BoardTargetPriorityParams(wireParams: retry.action.params)
        XCTAssertEqual(params, BoardTargetPriorityParams(workbenchID: DemoSeed.acmeID, priority: .low, fromPriority: .medium))
    }

    func testNoDismissesTheConflict() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))
        try await fail(fixture, reason: .conflict, result: ["current": .string("blocked")], message: "Changed on the Mac to blocked")
        let row = try XCTUnwrap(try detail(415, try snapshot(fixture.store)).writes.first)

        try fixture.writer.dismiss(row)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    func testAConflictWithoutACurrentValueIsAnOrdinaryFailure() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))
        try await fail(fixture, reason: .conflict, message: "Changed on the Mac")

        let row = try XCTUnwrap(try detail(415, try snapshot(fixture.store)).writes.first)
        XCTAssertEqual(row.state, .failed("Changed on the Mac"))
    }

    func testOtherFailuresShowTheHubsMessageOrAShortFallback() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))
        try await fail(fixture, reason: .notFound, message: "This target no longer exists on the Mac")
        XCTAssertEqual(
            try detail(415, try snapshot(fixture.store)).writes.first?.state,
            .failed("This target no longer exists on the Mac")
        )

        // The outbox's own fallback text is replaced by the phone's.
        let other = try makeFixture()
        try await other.writer.setPriority(.low, on: try target(415))
        try await fail(other, reason: .writeFailed, message: nil)
        XCTAssertEqual(try detail(415, try snapshot(other.store)).writes.first?.state, .failed("Your Mac could not make this change"))
    }

    // MARK: - Offline

    func testAPendingRowWaitsForTheMacWhileTheHeartbeatIsStale() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))

        let stale = try detail(415, try snapshot(fixture.store, heartbeatAge: 800))
        XCTAssertEqual(stale.writes.first?.state, .sending("Waiting for your Mac"))
        let none = try detail(415, try snapshot(fixture.store))
        XCTAssertEqual(none.writes.first?.state, .sending("Waiting for your Mac"), "no heartbeat yet is not online")
        let online = try detail(415, try snapshot(fixture.store, heartbeatAge: 10))
        XCTAssertEqual(online.writes.first?.state, .sending("Sending…"))
    }

    // MARK: - Comments

    func testTheComposerRefusesWhitespaceOnly() async throws {
        var draft = CommentDraft()
        draft.text = "  \n\t "
        XCTAssertFalse(draft.canSend)
        draft.text = " ok "
        XCTAssertTrue(draft.canSend)

        let fixture = try makeFixture()
        let sent = try await fixture.writer.addComment("   \n", on: try target(415))
        XCTAssertFalse(sent)
        let replied = try await fixture.writer.reply(" ", toRoot: 80, workbenchID: DemoSeed.acmeID)
        XCTAssertFalse(replied)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    func testTheCommentBodyIsCappedAt4000Characters() {
        var draft = CommentDraft()
        draft.text = String(repeating: "é", count: 4_100)
        XCTAssertEqual(draft.text.count, 4_000)
    }

    func testACommentAndAReplyShowPendingInTheThread() async throws {
        let fixture = try makeFixture()
        let sent = try await fixture.writer.addComment(" Looks good. ", on: try target(415))
        XCTAssertTrue(sent)
        let replied = try await fixture.writer.reply("Thanks", toRoot: 80, workbenchID: DemoSeed.acmeID)
        XCTAssertTrue(replied)

        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.map(\.action.kind), [.boardCommentAdd, .boardCommentReply])
        XCTAssertEqual(rows.map(\.entityRecordName), ["workbench_target-415", "workbench_comment-80"])
        XCTAssertEqual(try BoardCommentAddParams(wireParams: rows[0].action.params).body, "Looks good.")
        XCTAssertEqual(try BoardCommentReplyParams(wireParams: rows[1].action.params).body, "Thanks")

        let thread = try detail(415, try snapshot(fixture.store)).thread
        XCTAssertEqual(thread.map(\.id), ["comment-80", "comment-81", "action-\(rows[1].id)", "action-\(rows[0].id)"])
        XCTAssertEqual(thread.map(\.isReply), [false, true, true, false])
    }

    func testEveryRootOffersReplyEvenAResolvedOne() throws {
        let thread = try detail(421, try snapshot(try ReplicaStore.inMemory())).thread
        guard case let .comment(root)? = thread.first else { return XCTFail("no root comment on #421") }
        XCTAssertTrue(root.isResolved)
        XCTAssertTrue(root.canReply)
        XCTAssertEqual(root.rootID, root.id)
    }

    // MARK: - New target

    func testTheNewTargetTitleIsCappedAt200UnicodeScalarsOnAGraphemeBoundary() {
        var draft = NewBoardTargetDraft(workbenchID: DemoSeed.acmeID)
        draft.title = String(repeating: "a", count: 250)
        XCTAssertEqual(draft.title.unicodeScalars.count, 200)

        // A five-scalar ZWJ family past scalar 199 is dropped whole.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        draft.title = String(repeating: "a", count: 198) + family + "b"
        XCTAssertEqual(draft.title, String(repeating: "a", count: 198))
        XCTAssertLessThanOrEqual(draft.title.unicodeScalars.count, 200)

        draft.title = "   "
        XCTAssertFalse(draft.canCreate)
        draft.title = "Ask colleague A"
        XCTAssertTrue(draft.canCreate)
    }

    func testTheParentPickerListsOnlyThisWorkbenchsLiveTargets() throws {
        let snapshot = try demoSnapshot(now: now)
        let parents = NewBoardTargetDraft.parentOptions(workbenchID: DemoSeed.acmeID, snapshot: snapshot)
        let ids = Set(parents.map(\.id))
        let expected = Set(snapshot.targets.filter { $0.workbenchID == DemoSeed.acmeID && !$0.archived }.map(\.id))
        XCTAssertEqual(ids, expected)
        XCTAssertFalse(ids.contains(500), "another workbench's target")
        XCTAssertFalse(ids.contains(417), "an archived target")
    }

    func testCreateSendsTheDraftWithMediumByDefault() async throws {
        let fixture = try makeFixture()
        var draft = NewBoardTargetDraft(workbenchID: DemoSeed.acmeID, parentID: 400)
        XCTAssertEqual(draft.priority, .medium)
        draft.title = "  Ask colleague A  "
        let created = try await fixture.writer.create(draft)
        XCTAssertTrue(created)

        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .boardTargetCreate)
        XCTAssertNil(row.entityRecordName)
        XCTAssertNil(row.action.entityID)
        XCTAssertEqual(
            try BoardTargetCreateParams(wireParams: row.action.params),
            BoardTargetCreateParams(workbenchID: DemoSeed.acmeID, parentID: 400, text: "Ask colleague A", intent: "", priority: .medium)
        )

        // The board shows it as a pending row until hydration delivers it.
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: try snapshot(fixture.store), filter: .open)
        XCTAssertEqual(board.pendingCreates.map(\.title), ["Ask colleague A"])
        XCTAssertEqual(board.pendingCreates.first?.state, .sending("Waiting for your Mac"))
        XCTAssertTrue(BoardModel(workbenchID: DemoSeed.websiteID, snapshot: try snapshot(fixture.store), filter: .open).pendingCreates.isEmpty)

        var empty = NewBoardTargetDraft(workbenchID: DemoSeed.acmeID)
        empty.title = " "
        let refused = try await fixture.writer.create(empty)
        XCTAssertFalse(refused)
        XCTAssertEqual(try fixture.store.pendingActions().count, 1)
    }

    // MARK: - Fix round 1

    /// A transport whose saves wait until released: the window before the
    /// overlay row exists. `onSave` runs as each save starts waiting.
    /// `release()` is sticky: a save arriving after it passes straight
    /// through, so a late save never hangs the test.
    private final class GatedTransport: CloudSyncTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var saveHook: (() -> Void)?
        private var released = false

        var waiting: Int { lock.withLock { waiters.count } }

        var onSave: (() -> Void)? {
            get { lock.withLock { saveHook } }
            set { lock.withLock { saveHook = newValue } }
        }

        func release() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                released = true
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }

        func save(_ records: [CloudRecord]) async throws {
            await withCheckedContinuation { continuation in
                let (passes, hook) = lock.withLock { () -> (Bool, (() -> Void)?) in
                    if released { return (true, nil) }
                    waiters.append(continuation)
                    return (false, saveHook)
                }
                if passes {
                    continuation.resume()
                } else {
                    hook?()
                }
            }
        }

        func delete(recordNames: [String], in zone: CloudZoneID) async throws {}

        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: CloudChangeToken(value: 0))
        }
    }

    private func makeGatedFixture() throws -> (Fixture, GatedTransport) {
        let store = try ReplicaStore.inMemory()
        let transport = GatedTransport()
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: DemoSeed.device.deviceID)
        addTeardownBlock { transport.release() }
        return (Fixture(store: store, outbox: outbox, writer: BoardWriter.sending(through: outbox, store: store)), transport)
    }

    /// Starts `first` and waits (bounded) until its save is held at the gate.
    private func holdFirstSave<T>(
        _ transport: GatedTransport, _ first: @escaping @MainActor () async throws -> T
    ) async -> Task<T, Error> {
        let started = expectation(description: "the first save started")
        transport.onSave = { started.fulfill() }
        let task = Task { try await first() }
        await fulfillment(of: [started], timeout: 2)
        transport.onSave = nil
        return task
    }

    /// Runs `second` while the first save is held and waits for it to return
    /// within a bounded time: a missing guard makes it wait at the gate, so
    /// the wait fails (instead of the test deadlocking).
    private func runSecondWhileHeld<T>(_ second: @escaping @MainActor () async throws -> T) async -> Task<T, Error> {
        let returned = expectation(description: "the second send returned without saving")
        let task = Task {
            defer { returned.fulfill() }
            return try await second()
        }
        await fulfillment(of: [returned], timeout: 2)
        return task
    }

    /// The gate stays open once released: a save after the release passes.
    func testTheGatedTransportsReleaseIsSticky() async throws {
        let transport = GatedTransport()
        transport.release()
        let passed = expectation(description: "a save after the release passes")
        Task {
            try await transport.save([])
            passed.fulfill()
        }
        await fulfillment(of: [passed], timeout: 2)
        XCTAssertEqual(transport.waiting, 0)
    }

    func testADoubleTapOnSendPostsOneComment() async throws {
        let (fixture, transport) = try makeGatedFixture()
        let target = try target(415)
        let first = await holdFirstSave(transport) { try await fixture.writer.addComment("Looks good.", on: target) }

        let detail = try XCTUnwrap(BoardTargetDetailModel(
            targetID: 415, snapshot: try snapshot(fixture.store), now: now, inFlight: fixture.writer.inFlight
        ))
        XCTAssertTrue(detail.composerSending(replyRoot: nil), "Send is locked while the comment is on its way")
        XCTAssertFalse(detail.composerSending(replyRoot: 80))
        let second = await runSecondWhileHeld { try await fixture.writer.addComment("Looks good.", on: target) }
        XCTAssertEqual(transport.waiting, 1, "the second tap reached the transport")

        transport.release()
        let sentFirst = try await first.value
        let sentSecond = try await second.value
        XCTAssertTrue(sentFirst)
        XCTAssertFalse(sentSecond)
        XCTAssertEqual(try fixture.store.pendingActions().count, 1)
        XCTAssertTrue(fixture.writer.inFlight.isEmpty)
    }

    func testTwoPicksOnOneFieldDuringTheSaveSendOneAction() async throws {
        let (fixture, transport) = try makeGatedFixture()
        let target = try target(415)
        let first = await holdFirstSave(transport) { try await fixture.writer.setStatus(.done, on: target) }

        let detail = try XCTUnwrap(BoardTargetDetailModel(
            targetID: 415, snapshot: try snapshot(fixture.store), now: now, inFlight: fixture.writer.inFlight
        ))
        XCTAssertFalse(detail.status.isEnabled, "the picker is locked while its write is on its way")
        XCTAssertTrue(detail.priority.isEnabled)
        let second = await runSecondWhileHeld { try await fixture.writer.setStatus(.blocked, on: target) }
        XCTAssertEqual(transport.waiting, 1, "the second pick reached the transport")

        transport.release()
        try await first.value
        try await second.value
        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try BoardTargetStatusParams(wireParams: try XCTUnwrap(rows.first).action.params).status, .done)
    }

    func testANewerPickDropsTheFieldsOldConflict() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.setStatus(.done, on: try target(415))
        try await fail(fixture, reason: .conflict, result: ["current": .string("blocked")], message: "Changed on the Mac to blocked")
        try await fixture.writer.setPriority(.low, on: try target(415))

        try await fixture.writer.setStatus(.todo, on: try target(415))

        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.map(\.action.kind), [.boardTargetPriority, .boardTargetStatus], "only the status conflict went")
        XCTAssertEqual(rows.map(\.state), [.pending, .pending])
        XCTAssertEqual(try BoardTargetStatusParams(wireParams: rows[1].action.params).status, .todo)
    }

    func testAReplyIsOfferedOnlyOnARealRoot() throws {
        var pruned = try demoSnapshot(now: now)
        pruned.comments.removeAll { $0.id == 80 }
        let thread = try detail(415, pruned).thread
        guard case let .comment(orphan)? = thread.first else { return XCTFail("no comment on #415") }
        XCTAssertEqual(orphan.id, 81)
        XCTAssertFalse(orphan.isReply, "shown as a root")
        XCTAssertFalse(orphan.canReply, "but the hub would refuse a reply under it")
    }

    func testAReplyWhoseRootIsNotShownStillShowsAndCanBeDismissed() async throws {
        let fixture = try makeFixture()
        try await fixture.writer.reply("Thanks", toRoot: 80, workbenchID: DemoSeed.acmeID)
        try await fail(fixture, reason: .notFound, message: "This comment no longer exists on the Mac")

        var pruned = try snapshot(fixture.store)
        pruned.comments.removeAll { $0.id == 80 }
        let thread = try detail(415, pruned).thread
        guard case let .write(row, _)? = thread.last else { return XCTFail("the reply is not in the thread") }
        XCTAssertEqual(row.state, .failed("This comment no longer exists on the Mac"))
        try fixture.writer.dismiss(row)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)

        // With no trace of its thread in the replica, the board shows it.
        let other = try makeFixture()
        try await other.writer.reply("Thanks", toRoot: 999, workbenchID: DemoSeed.acmeID)
        let orphaned = try snapshot(other.store)
        XCTAssertFalse(try detail(415, orphaned).thread.contains { if case .write = $0 { true } else { false } })
        XCTAssertEqual(BoardModel(workbenchID: DemoSeed.acmeID, snapshot: orphaned, filter: .open).unplacedReplies.map(\.title), ["Thanks"])
        XCTAssertTrue(BoardModel(workbenchID: DemoSeed.websiteID, snapshot: orphaned, filter: .open).unplacedReplies.isEmpty)
    }

    // MARK: - Breadcrumb

    func testTheBreadcrumbFollowsTheParentChainInsideTheReplica() throws {
        let snapshot = try demoSnapshot(now: now)
        XCTAssertEqual(try detail(415, snapshot).breadcrumb.map(\.id), [400])
        XCTAssertEqual(try detail(400, snapshot).breadcrumb, [])

        var orphan = snapshot
        orphan.targets.removeAll { $0.id == 400 }
        XCTAssertEqual(try detail(415, orphan).breadcrumb, [], "an unpublished parent ends the chain")
    }
}
