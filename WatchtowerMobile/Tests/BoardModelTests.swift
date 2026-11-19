import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The board row's and the detail's status label: the Mac's column title
/// when the workbench defines columns (board #267), else the status label.
final class BoardModelTests: XCTestCase {
    private let now = Date()

    private func snapshot(column: String?) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        let source = try XCTUnwrap(snapshot.targets.first { $0.id == 416 })
        var json: [String: Any] = [
            "id": source.id, "workbench_id": source.workbenchID, "text": source.text, "text_clipped": false,
            "intent": "", "status": "in_progress", "priority": "medium", "progress": 0.0, "branch": "", "pr": "",
            "archived": false, "children_count": 0, "open_comments": 0, "unread_for_owner": 0, "open_asks": 0,
            "session_ids": [Int64](), "work_on_prompt": "",
            "created_at": 1_699_990_000, "updated_at": 1_699_990_000
        ]
        if let column { json["column"] = column }
        snapshot.targets = [try mirror(WorkbenchTarget.self, json)]
        return snapshot
    }

    /// Live link R5: a live priority overlay changes the card in place with the pending caption; a moved card
    /// leaves the Mac's column for its new status's lane.
    @MainActor
    func testAnOverlayChangesTheCardInPlace() throws {
        let replica = try snapshot(column: "QA")
        let book = OverlayBook(hubID: "hub")
        book.add(book.overlay(actionID: "p1", entityID: 416, expected: .priority(.high), createdAt: now))
        book.add(book.overlay(actionID: "s1", entityID: 416, expected: .status(.blocked), createdAt: now))
        let shown = replica.applying(book.reconcile(with: replica, now: now))
        XCTAssertEqual(shown.overlays.map(\.actionID), ["p1", "s1"])
        let board = BoardModel(workbenchID: DemoSeed.acmeID, snapshot: shown, filter: .all, now: now)
        let lane = try XCTUnwrap(board.lanes.first { $0.nodes.contains { $0.id == 416 } })
        XCTAssertEqual(lane.title, "Blocked")
        let node = try XCTUnwrap(lane.nodes.first { $0.id == 416 })
        XCTAssertEqual(node.card.priorityDot, .red)
        XCTAssertEqual(node.caption?.state, .sending(BoardWriteText.waitingForMac), "the demo board has no heartbeat")
        XCTAssertTrue(node.opensDetail)
    }

    func testRowShowsColumnTitle() throws {
        let withColumn = try snapshot(column: "QA")
        let target = try XCTUnwrap(withColumn.targets.first)
        XCTAssertEqual(BoardRowModel(target, snapshot: withColumn).statusText, "QA")
        let detail = try XCTUnwrap(BoardTargetDetailModel(targetID: target.id, snapshot: withColumn, now: now))
        XCTAssertEqual(detail.statusLabel, "QA")

        let without = try snapshot(column: nil)
        let plain = try XCTUnwrap(without.targets.first)
        XCTAssertEqual(BoardRowModel(plain, snapshot: without).statusText, "In progress")
        XCTAssertEqual(try XCTUnwrap(BoardTargetDetailModel(targetID: plain.id, snapshot: without, now: now)).statusLabel, "In progress")
    }

    /// The board card keeps the old rows' meta: open asks in the waiting
    /// tone and the PR text (the live-session dot is the card's own).
    func testCardCarriesAsksAndPR() throws {
        let snapshot = try demoSnapshot(now: now)
        let target = try XCTUnwrap(snapshot.targets.first { $0.id == 415 })
        let card = BoardRowModel(target, snapshot: snapshot).card
        let asks = try XCTUnwrap(card.details.first { $0.role == .ask })
        XCTAssertEqual(asks.text, "2 asks")
        XCTAssertEqual(asks.tone, .waitingForYou)
        XCTAssertTrue(card.details.contains { $0.text == "PR #175" })
        XCTAssertFalse(card.details.contains { $0.text == "Session working" })
    }

    /// #1781: groups start folded, lanes open but Backlog and Done; a flip
    /// is remembered per hub and workbench, and forgetting the Mac removes it.
    @MainActor
    func testFoldsAreRememberedPerHubAndWorkbench() throws {
        let suite = "board-folds-test"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backlog = BoardLane(title: "Backlog", nodes: [], kind: .open)
        let todo = BoardLane(title: "Todo", nodes: [], kind: .open)

        let store = BoardFoldStore(defaults: defaults)
        let fresh = store.folds(hubID: "hub-a", workbenchID: 1)
        XCTAssertFalse(fresh.isGroupOpen(400))
        XCTAssertFalse(fresh.isLaneOpen(backlog))
        XCTAssertTrue(fresh.isLaneOpen(todo))

        store.update(hubID: "hub-a", workbenchID: 1) {
            $0.toggleGroup(400)
            $0.toggleLane(backlog)
            $0.toggleLane(todo)
        }
        let reopened = BoardFoldStore(defaults: defaults).folds(hubID: "hub-a", workbenchID: 1)
        XCTAssertTrue(reopened.isGroupOpen(400))
        XCTAssertTrue(reopened.isLaneOpen(backlog))
        XCTAssertFalse(reopened.isLaneOpen(todo))
        XCTAssertEqual(BoardFoldStore(defaults: defaults).folds(hubID: "hub-a", workbenchID: 2), BoardFolds(), "per workbench")
        XCTAssertEqual(BoardFoldStore(defaults: defaults).folds(hubID: "hub-b", workbenchID: 1), BoardFolds(), "per hub")

        store.update(hubID: "hub-a", workbenchID: 1) { $0.toggleGroup(400) }
        XCTAssertFalse(BoardFoldStore(defaults: defaults).folds(hubID: "hub-a", workbenchID: 1).isGroupOpen(400))

        DeviceSettings.removeChoices(of: "hub-a", defaults: defaults)
        XCTAssertEqual(BoardFoldStore(defaults: defaults).folds(hubID: "hub-a", workbenchID: 1), BoardFolds())
    }

    /// Forgetting a Mac drops its folds from the running store too, so
    /// linking the same Mac again starts over (codex review of #873).
    @MainActor
    func testForgettingAHubDropsItsFoldsInMemory() throws {
        let suite = "board-folds-forget"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoardFoldStore(defaults: defaults)
        store.update(hubID: "hub-a", workbenchID: 1) { $0.toggleGroup(400) }
        store.update(hubID: "hub-b", workbenchID: 1) { $0.toggleGroup(400) }
        XCTAssertTrue(store.folds(hubID: "hub-a", workbenchID: 1).isGroupOpen(400))

        store.forget(hubID: "hub-a")
        XCTAssertEqual(store.folds(hubID: "hub-a", workbenchID: 1), BoardFolds())
        XCTAssertNil(defaults.data(forKey: BoardFoldStore.key(hubID: "hub-a")))
        XCTAssertTrue(store.folds(hubID: "hub-b", workbenchID: 1).isGroupOpen(400), "another tower keeps its folds")
    }

    /// A damaged entry reads as no flips rather than failing the board.
    @MainActor
    func testUnreadableFoldsReadAsNone() throws {
        let suite = "board-folds-bad"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: BoardFoldStore.key(hubID: "hub-a"))
        XCTAssertEqual(BoardFoldStore(defaults: defaults).folds(hubID: "hub-a", workbenchID: 1), BoardFolds())
    }
}
