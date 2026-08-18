import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The app-wide registry of target assistant containers: identity, the LRU
/// bound, and the rule that a working agent is never evicted.
@MainActor
final class TargetAssistantCenterTests: XCTestCase {
    private func makeManager() throws -> (DatabaseManager, String) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
        return (manager, path)
    }

    private func makeTarget(_ manager: DatabaseManager, text: String) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text, intent: "x",
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    /// A center whose containers stream through a mock, so a turn can be held
    /// open on demand.
    private func makeCenter(limit: Int) -> TargetAssistantCenter {
        TargetAssistantCenter(limit: limit) { target, targets, manager in
            TargetAssistantViewModel(
                target: target, viewModel: targets, dbManager: manager
            ) { conversationID in
                TargetChatViewModel(
                    target: target, viewModel: targets, dbManager: manager,
                    conversationID: conversationID,
                    aiService: MockClaudeService(events: [.sessionID("s1"), .text("reply"), .done]),
                    provider: .claude
                )
            }
        }
    }

    private func waitForIdle(_ container: TargetAssistantViewModel, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while container.isAnyWorking {
            if Date() > deadline {
                XCTFail("container stayed busy for \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testReturnsTheSameContainerForTheSameTarget() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, text: "one")
        let targets = TargetsViewModel(dbManager: manager)
        let center = makeCenter(limit: 4)

        let first = center.container(for: target, viewModel: targets, dbManager: manager)
        let second = center.container(for: target, viewModel: targets, dbManager: manager)

        XCTAssertTrue(first === second, "a target's tabs must survive leaving and re-entering its screen")
        XCTAssertEqual(center.count, 1)
    }

    func testEvictsTheLeastRecentlyUsedContainerBeyondTheLimit() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let targets = TargetsViewModel(dbManager: manager)
        let center = makeCenter(limit: 2)
        let a = try makeTarget(manager, text: "a")
        let b = try makeTarget(manager, text: "b")
        let c = try makeTarget(manager, text: "c")

        _ = center.container(for: a, viewModel: targets, dbManager: manager)
        _ = center.container(for: b, viewModel: targets, dbManager: manager)
        // Re-touch A so B becomes the least recently used one.
        _ = center.container(for: a, viewModel: targets, dbManager: manager)
        _ = center.container(for: c, viewModel: targets, dbManager: manager)

        XCTAssertEqual(center.count, 2)
        XCTAssertNil(center.loaded(b.id))
        XCTAssertNotNil(center.loaded(a.id))
        XCTAssertNotNil(center.loaded(c.id))
    }

    /// The bound must never kill a working agent: a busy container stays over
    /// the limit until it goes idle, and only then can be trimmed.
    func testNeverEvictsAContainerWhileOneOfItsTabsIsStreaming() async throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let targets = TargetsViewModel(dbManager: manager)
        let center = makeCenter(limit: 1)
        let busy = try makeTarget(manager, text: "busy")
        let other = try makeTarget(manager, text: "other")
        let third = try makeTarget(manager, text: "third")

        let busyContainer = center.container(for: busy, viewModel: targets, dbManager: manager)
        let chat = try XCTUnwrap(busyContainer.activeChat)
        chat.inputText = "keep working"
        chat.send()
        XCTAssertTrue(busyContainer.isAnyWorking)

        // Over the limit, but the busy container must survive.
        _ = center.container(for: other, viewModel: targets, dbManager: manager)
        XCTAssertEqual(center.count, 2)
        XCTAssertNotNil(center.loaded(busy.id))

        try await waitForIdle(busyContainer)

        // Idle now — the next use trims it like any other cold container.
        _ = center.container(for: third, viewModel: targets, dbManager: manager)
        XCTAssertEqual(center.count, 1)
        XCTAssertNil(center.loaded(busy.id))
        XCTAssertNotNil(center.loaded(third.id))
    }

    func testDropRemovesTheContainer() throws {
        let (manager, path) = try makeManager()
        defer { TestDatabase.cleanup(path: path) }
        let targets = TargetsViewModel(dbManager: manager)
        let center = makeCenter(limit: 4)
        let target = try makeTarget(manager, text: "gone")

        _ = center.container(for: target, viewModel: targets, dbManager: manager)
        center.drop(targetID: target.id)

        XCTAssertEqual(center.count, 0)
        XCTAssertNil(center.loaded(target.id))
    }
}
