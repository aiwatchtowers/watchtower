import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Optimistic overlays (live link R5): a board write or an ask answer shows its expected effect at tap time, marked
/// pending, until the replica shows it; the echo alone never clears one. One test per failure-table row R5 owns.
@MainActor
final class PendingOverlayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func book(_ hubID: String = "hub-a", confirm: @escaping (ActionKind, Int, Date) -> Void = { _, _, _ in }) -> OverlayBook {
        OverlayBook(hubID: hubID, recordConfirm: confirm)
    }

    /// The demo board with a fresh heartbeat (or one `heartbeatAge` old) and `pending` as the outbox overlay.
    private func replica(
        targets change: (inout [WorkbenchTarget]) throws -> Void = { _ in },
        comments: [WorkbenchComment] = [],
        pending: [PendingAction] = [],
        heartbeatAge: TimeInterval = 10,
        at now: Date? = nil
    ) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: t0)
        try change(&snapshot.targets)
        snapshot.comments += comments
        snapshot.pending = pending
        let at = (now ?? t0).addingTimeInterval(-heartbeatAge)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "_user", sharing: .none
        )
        return snapshot
    }

    private func set(_ id: Int64, status: WorkbenchTargetStatus) -> (inout [WorkbenchTarget]) -> Void {
        { targets in
            targets = targets.map { $0.id == id ? $0.overlaid(status: status) : $0 }
        }
    }

    private func newTarget(_ id: Int64, title: String, parent: Int64? = nil) throws -> WorkbenchTarget {
        var overrides: [String: Any] = ["text": title]
        if let parent { overrides["parent_id"] = parent }
        return try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(id, workbench: DemoSeed.acmeID, overrides))
    }

    private func echo(
        _ id: String, _ kind: ActionKind, entity: Int64?, _ status: ActionStatus = .applied, result: [String: JSONValue]? = nil
    ) -> ActionRequestPayload {
        var echo = ActionRequestPayload(
            id: id, kind: kind, entityID: entity.map(String.init), createdAt: t0, deviceID: DemoSeed.device.deviceID)
        echo.status = status
        echo.result = result
        return echo
    }

    private func status(_ book: OverlayBook, _ id: String = "a1", on target: Int64 = 415, _ value: WorkbenchTargetStatus = .inReview) {
        book.add(book.overlay(actionID: id, entityID: target, expected: .status(value), createdAt: t0))
    }

    private func create(_ book: OverlayBook, _ id: String = "c1", title: String = "Fix login timeout") {
        book.add(book.overlay(
            actionID: id, entityID: nil,
            expected: .create(workbenchID: DemoSeed.acmeID, parentID: nil, title: title, priority: .medium), createdAt: t0))
    }

    private func lane(of title: String, in board: BoardModel) -> BoardLane? {
        board.lanes.first { $0.nodes.contains { $0.card.title == title } }
    }

    /// The node anywhere in the board's trees.
    private func node(_ id: Int64, in board: BoardModel) -> BoardNode? {
        func all(_ nodes: [BoardNode]) -> [BoardNode] { nodes.flatMap { [$0] + all($0.children) } }
        return all(board.lanes.flatMap(\.nodes)).first { $0.id == id }
    }

    // MARK: - Change of an existing entity

    func testStatusOverlayClearsWhenReplicaShowsIt_sliceBeforeEcho() throws {
        var confirms: [Int] = []
        let book = book { _, ms, _ in confirms.append(ms) }
        status(book)
        let before = try replica()
        XCTAssertEqual(book.reconcile(with: before, now: t0).map(\.actionID), ["a1"])

        // The applied snapshot moves the card at tap time.
        let shown = before.applying(book.reconcile(with: before, now: t0))
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: shown, filter: .all, now: t0)
        XCTAssertEqual(node(415, in: board)?.status, .inReview)
        XCTAssertEqual(node(415, in: board)?.caption?.state, .sending(BoardWriteText.sending))

        // The slice comes first: dropped at once, no 30 s wait.
        let slice = try replica(targets: set(415, status: .inReview))
        XCTAssertTrue(book.reconcile(with: slice, now: t0.addingTimeInterval(0.4)).isEmpty)
        XCTAssertTrue(book.overlays.isEmpty)

        // The late echo still times the tap.
        book.receiveEcho(echo("a1", .boardTargetStatus, entity: 415), now: t0.addingTimeInterval(0.6))
        XCTAssertEqual(confirms, [600])
    }

    func testStatusOverlayClearsWhenReplicaShowsIt_echoBeforeSlice() throws {
        let book = book()
        status(book)
        let before = try replica()
        _ = book.reconcile(with: before, now: t0)
        book.receiveEcho(echo("a1", .boardTargetStatus, entity: 415), now: t0.addingTimeInterval(0.2))

        // The echo alone never clears it: no flicker back.
        let live = book.reconcile(with: before, now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(live.map(\.actionID), ["a1"])
        XCTAssertEqual(live.first?.caption(macOnline: true), .sending(BoardWriteText.sending))
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: before.applying(live), filter: .all, now: t0)
        XCTAssertEqual(node(415, in: board)?.status, .inReview)

        XCTAssertTrue(book.reconcile(with: try replica(targets: set(415, status: .inReview)), now: t0.addingTimeInterval(0.9)).isEmpty)
    }

    func testAppliedWithoutVisibleEffectDropsAfter30s() throws {
        let book = book()
        status(book)
        let before = try replica()
        _ = book.reconcile(with: before, now: t0)
        book.receiveEcho(echo("a1", .boardTargetStatus, entity: 415), now: t0.addingTimeInterval(1))
        XCTAssertEqual(book.reconcile(with: before, now: t0.addingTimeInterval(30.9)).count, 1)
        XCTAssertTrue(book.reconcile(with: before, now: t0.addingTimeInterval(31)).isEmpty)
    }

    func testOvertakenEffectDropsAtNextRecord() throws {
        let book = book()
        status(book)
        _ = book.reconcile(with: try replica(), now: t0)
        book.receiveEcho(echo("a1", .boardTargetStatus, entity: 415), now: t0.addingTimeInterval(1))
        // Someone moved it again right after: the next record of that entity wins, not the 30 s wait.
        let overtaken = try replica(targets: set(415, status: .blocked))
        XCTAssertTrue(book.reconcile(with: overtaken, now: t0.addingTimeInterval(2)).isEmpty)
    }

    // MARK: - Create and comment

    func testCreateMatchedByEchoTargetID() throws {
        let book = book()
        create(book)
        let before = try replica()
        XCTAssertEqual(book.reconcile(with: before, now: t0).count, 1)

        // The new card is in To Do at tap time.
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: before.applying(book.reconcile(with: before, now: t0)), filter: .all, now: t0)
        let card = try XCTUnwrap(board.lanes.flatMap(\.nodes).first { $0.card.title == "Fix login timeout" })
        XCTAssertEqual(lane(of: "Fix login timeout", in: board)?.title, "Todo")
        XCTAssertFalse(card.opensDetail, "an overlay has no target to open")
        XCTAssertEqual(card.caption?.state, .sending(BoardWriteText.sending))

        book.receiveEcho(echo("c1", .boardTargetCreate, entity: nil, result: ["target_id": .integer(900)]), now: t0.addingTimeInterval(0.2))
        XCTAssertEqual(book.reconcile(with: before, now: t0.addingTimeInterval(0.3)).count, 1, "kept until the record arrives")
        let arrived = try replica { $0.append(try self.newTarget(900, title: "Fix login timeout")) }
        XCTAssertTrue(book.reconcile(with: arrived, now: t0.addingTimeInterval(0.9)).isEmpty)
        XCTAssertTrue(book.overlays.isEmpty)
    }

    func testCreateMatchedByTitleAndParentBeforeEcho_noDuplicate() throws {
        let book = book()
        create(book)
        // A target with the same title that predates the tap hides nothing.
        let before = try replica { $0.append(try self.newTarget(899, title: "Fix login timeout")) }
        XCTAssertEqual(book.reconcile(with: before, now: t0).count, 1)

        // The slice comes first: the new card replaces the overlay.
        let arrived = try replica {
            $0.append(try self.newTarget(899, title: "Fix login timeout"))
            $0.append(try self.newTarget(900, title: "Fix login timeout"))
        }
        let live = book.reconcile(with: arrived, now: t0.addingTimeInterval(0.4))
        XCTAssertTrue(live.isEmpty)
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: arrived.applying(live), filter: .all, now: t0)
        XCTAssertEqual(board.lanes.flatMap(\.nodes).filter { $0.card.title == "Fix login timeout" }.map(\.id), [899, 900])
        XCTAssertEqual(book.overlays.count, 1, "hidden until the echo confirms the match")

        book.receiveEcho(echo("c1", .boardTargetCreate, entity: nil, result: ["target_id": .integer(900)]), now: t0.addingTimeInterval(0.6))
        XCTAssertTrue(book.reconcile(with: arrived, now: t0.addingTimeInterval(0.7)).isEmpty)
        XCTAssertTrue(book.overlays.isEmpty)
    }

    func testCommentMatchedByEchoCommentID() throws {
        let book = book()
        book.add(book.overlay(actionID: "m1", entityID: 415, expected: .comment(body: "Looks good", isReply: false), createdAt: t0))
        let before = try replica()
        XCTAssertEqual(book.reconcile(with: before, now: t0).count, 1)
        book.receiveEcho(echo("m1", .boardCommentAdd, entity: 415, result: ["comment_id": .integer(77)]), now: t0.addingTimeInterval(0.2))
        XCTAssertEqual(book.reconcile(with: before, now: t0.addingTimeInterval(0.3)).count, 1)

        let comment = try mirror(WorkbenchComment.self, DemoSeed.JSON.comment(
            77, workbench: DemoSeed.acmeID, target: 415, ["author": "owner", "body": "Looks good"]))
        XCTAssertTrue(book.reconcile(with: try replica(comments: [comment]), now: t0.addingTimeInterval(0.9)).isEmpty)
        XCTAssertEqual(PendingOverlay.Kind.comment, book.overlay(
            actionID: "x", entityID: 1, expected: .comment(body: "b", isReply: true), createdAt: t0).kind)
    }

    // MARK: - Refusal, a slow tower, expiry

    func testRefusedEchoDropsOverlayAndShowsRefusal() async throws {
        var confirms: [Int] = []
        let book = book { _, ms, _ in confirms.append(ms) }
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let writer = BoardWriter.sending(through: outbox, store: store, overlays: book) { self.t0 }
        let target = try XCTUnwrap(try replica().targets.first { $0.id == 415 })
        try await writer.setStatus(.done, on: target)
        XCTAssertEqual(book.overlays.map(\.kind), [.status])

        var refusal = try XCTUnwrap(store.pendingActions().first).action
        refusal.status = .failed
        refusal.errorMessage = "Target is archived"
        try await outbox.applyEcho(refusal)
        book.receiveEcho(refusal, now: t0.addingTimeInterval(0.2))

        let snapshot = try replica(pending: try store.pendingActions())
        let live = book.reconcile(with: snapshot, now: t0.addingTimeInterval(0.2))
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(book.overlays.isEmpty)
        // The card is back in its lane with the refusal line and Dismiss.
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot.applying(live), filter: .all, now: t0)
        let card = try XCTUnwrap(node(415, in: board))
        XCTAssertEqual(card.status, .inProgress)
        XCTAssertEqual(card.caption?.state, .failed("Target is archived"))
        XCTAssertNotNil(card.caption?.row, "Dismiss needs the row")
        XCTAssertTrue(confirms.isEmpty, "a refusal times nothing")
    }

    func testNoEchoStaleHeartbeatCaptionIsWaiting() throws {
        let book = book()
        status(book)
        let stale = try replica(heartbeatAge: 3_600)
        let live = book.reconcile(with: stale, now: t0)
        XCTAssertEqual(live.first?.caption(macOnline: false), .sending(BoardWriteText.waitingForMac))
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: stale.applying(live), filter: .all, now: t0)
        XCTAssertEqual(node(415, in: board)?.caption?.state, .sending("Waiting for your tower"))

        // Once the tower answered, it is only the slice that is late.
        book.receiveEcho(echo("a1", .boardTargetStatus, entity: 415), now: t0.addingTimeInterval(1))
        XCTAssertEqual(book.reconcile(with: stale, now: t0.addingTimeInterval(1)).first?.caption(macOnline: false), .sending("Sending…"))
    }

    func testOverlayDroppedAfter10Minutes() async throws {
        let book = book()
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let writer = BoardWriter.sending(through: outbox, store: store, overlays: book) { self.t0 }
        var draft = NewBoardTargetDraft(workbenchID: DemoSeed.acmeID)
        draft.title = "Fix login timeout"
        try await writer.create(draft)

        let later = t0.addingTimeInterval(599)
        let snapshot = try replica(pending: try store.pendingActions(), heartbeatAge: 3_600, at: later)
        let live = book.reconcile(with: snapshot, now: later)
        XCTAssertEqual(live.count, 1)
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot.applying(live), filter: .all, now: later)
        XCTAssertTrue(board.pendingCreates.isEmpty, "the card is in its lane, no separate pending row")

        let expired = t0.addingTimeInterval(600)
        XCTAssertTrue(book.reconcile(with: snapshot, now: expired).isEmpty)
        let after = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot.applying([]), filter: .all, now: expired)
        XCTAssertEqual(after.pendingCreates.map(\.state), [.sending("Waiting for your tower")], "today's pending row takes over")
        XCTAssertNil(lane(of: "Fix login timeout", in: after))
    }

    // MARK: - Towers and relaunch

    func testOverlaysArePerTower() async throws {
        let towerA = book("hub-a")
        let towerB = book("hub-b")
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let writer = BoardWriter.sending(through: outbox, store: store, overlays: towerA) { self.t0 }
        try await writer.setStatus(.done, on: try XCTUnwrap(try replica().targets.first { $0.id == 415 }))

        XCTAssertEqual(towerA.overlays.map(\.hubID), ["hub-a"])
        XCTAssertTrue(towerB.overlays.isEmpty)
        let snapshot = try replica(pending: try store.pendingActions())
        XCTAssertTrue(snapshot.applying(towerB.reconcile(with: snapshot, now: t0)).overlays.isEmpty)
        XCTAssertEqual(snapshot.applying(towerA.reconcile(with: snapshot, now: t0)).overlays.count, 1)
    }

    func testRelaunchShowsPendingRowsWithoutOverlays() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let writer = BoardWriter.sending(through: outbox, store: store, overlays: book()) { self.t0 }
        var draft = NewBoardTargetDraft(workbenchID: DemoSeed.acmeID)
        draft.title = "Fix login timeout"
        try await writer.create(draft)
        try await writer.setStatus(.inReview, on: try XCTUnwrap(try replica().targets.first { $0.id == 415 }))

        // A relaunch starts with an empty book: today's pending rows show, nothing moves.
        let relaunched = book()
        let snapshot = try replica(pending: try store.pendingActions())
        let shown = snapshot.applying(relaunched.reconcile(with: snapshot, now: t0))
        XCTAssertTrue(shown.overlays.isEmpty)
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: shown, filter: .all, now: t0)
        XCTAssertEqual(board.pendingCreates.map(\.title), ["Fix login timeout"])
        XCTAssertEqual(node(415, in: board)?.status, .inProgress)
        XCTAssertNil(node(415, in: board)?.caption)
        XCTAssertEqual(try XCTUnwrap(BoardTargetDetailModel(targetID: 415, snapshot: shown, now: t0)).status.selection, .inReview)
    }

    /// The replica model shows the book's overlays over every read, at once when the book changes.
    func testTheReplicaModelShowsTheBooksOverlaysAtOnce() throws {
        let model = WorkbenchReplicaModel()
        let book = book()
        model.start(store: try TestPhone.replica(), overlays: book)
        create(book)
        XCTAssertEqual(model.snapshot.overlays.map(\.actionID), ["c1"])
        book.receiveEcho(echo("c1", .boardTargetCreate, entity: nil, .failed), now: t0)
        XCTAssertTrue(model.snapshot.overlays.isEmpty)
    }

    // MARK: - Captions and timing

    func testCaptionsAreExistingStrings() {
        let book = book()
        let overlay = book.overlay(actionID: "a1", entityID: 415, expected: .status(.done), createdAt: t0)
        XCTAssertEqual(overlay.caption(macOnline: true), .sending("Sending…"))
        XCTAssertEqual(overlay.caption(macOnline: false), .sending("Waiting for your tower"))
        XCTAssertEqual(BoardWriteText.sending, "Sending…")
        XCTAssertEqual(BoardWriteText.waitingForMac, "Waiting for your tower")
        XCTAssertEqual(BoardWriteText.genericFailure, "Your tower could not make this change")
    }

    func testConfirmSampleIsTapToAppliedEcho() throws {
        let store = try TestPhone.replica()
        let book = OverlayBook(hubID: "hub-a") { kind, ms, at in
            store.recordConfirm(kind: kind, ms: ms, transport: .relay, at: at)
        }
        status(book)
        status(book, "a2", on: 416)
        let before = try replica()
        _ = book.reconcile(with: before, now: t0)

        book.receiveEcho(echo("a1", .boardTargetStatus, entity: 415), now: t0.addingTimeInterval(0.18))
        book.receiveEcho(echo("a2", .boardTargetStatus, entity: 416, .failed), now: t0.addingTimeInterval(0.2))
        _ = book.reconcile(with: try replica(targets: set(415, status: .inReview)), now: t0.addingTimeInterval(0.9))

        let rows = try store.confirmSamples(since: .distantPast)
        XCTAssertEqual(rows.map(\.confirmMs), [180], "one row: the tap → the applied echo, not → the slice")
        XCTAssertEqual(rows.map(\.kind), ["board_target_status"])
        XCTAssertEqual(try XCTUnwrap(rows.first).at.timeIntervalSince(t0), 0.18, accuracy: 0.001, "stamped when the echo came")
    }
}
