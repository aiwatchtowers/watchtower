import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class CatchUpViewModelTests: XCTestCase {

    // MARK: - Seeding helpers

    nonisolated private static func insertSession(
        _ db: Database,
        status: String = "active",
        totalThemes: Int = 0,
        reviewedCount: Int = 0
    ) throws -> Int {
        try db.execute(
            sql: """
                INSERT INTO catchup_sessions (created_at, status, total_themes, reviewed_count)
                VALUES (?, ?, ?, ?)
                """,
            arguments: ["2026-06-20T00:00:00Z", status, totalThemes, reviewedCount]
        )
        return Int(db.lastInsertedRowID)
    }

    @discardableResult
    nonisolated private static func insertTheme(
        _ db: Database,
        sessionID: Int,
        orderIdx: Int = 0,
        title: String = "Theme",
        priority: String = "medium",
        refs: String = "[]",
        genState: String = "ready",
        reviewState: String = "pending"
    ) throws -> Int {
        try db.execute(
            sql: """
                INSERT INTO catchup_themes
                    (session_id, order_idx, title, narrative, priority, needs_you,
                     suggested_action, refs, gen_state, review_state, created_at, updated_at)
                VALUES (?, ?, ?, 'n', ?, 0, '', ?, ?, ?, ?, ?)
                """,
            arguments: [
                sessionID, orderIdx, title, priority, refs, genState, reviewState,
                "2026-06-20T00:00:00Z", "2026-06-20T00:00:00Z"
            ]
        )
        return Int(db.lastInsertedRowID)
    }

    nonisolated private static func insertInbox(_ db: Database) throws -> Int {
        try db.execute(sql: """
            INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, read_at)
            VALUES ('C1', '1.0', 'U1', 'mention', 'pending', NULL)
            """)
        return Int(db.lastInsertedRowID)
    }

    /// Pumps the run loop so the VM's ValueObservation Task can deliver its first value.
    private func waitFor(
        _ predicate: @escaping () -> Bool, timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Observation populates themes and auto-selects first pending

    func testStartObservingPopulatesThemesAndSelectsFirstPending() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        try await pool.write { db in
            let sid = try Self.insertSession(db, totalThemes: 3)
            // order_idx 0 already reviewed → should be skipped by auto-select.
            try Self.insertTheme(db, sessionID: sid, orderIdx: 0, title: "Done", reviewState: "reviewed")
            try Self.insertTheme(db, sessionID: sid, orderIdx: 1, title: "First pending")
            try Self.insertTheme(db, sessionID: sid, orderIdx: 2, title: "Second pending")
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.startObserving()

        await waitFor { vm.themes.count == 3 }
        XCTAssertEqual(vm.themes.count, 3)
        XCTAssertEqual(vm.session?.totalThemes, 3)
        XCTAssertEqual(vm.selected?.title, "First pending", "auto-selects the first pending theme")
    }

    // MARK: - Acknowledge advances to next pending

    func testAcknowledgeAdvancesToNextPending() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let pool = manager.dbPool

        let inboxID = try await pool.write { db -> Int in
            let sid = try Self.insertSession(db, totalThemes: 2)
            let iid = try Self.insertInbox(db)
            try Self.insertTheme(
                db, sessionID: sid, orderIdx: 0, title: "First",
                refs: "[{\"area\":\"inbox\",\"id\":\(iid),\"label\":\"Ping\"}]"
            )
            try Self.insertTheme(db, sessionID: sid, orderIdx: 1, title: "Second")
            return iid
        }

        let vm = CatchUpViewModel(dbPool: pool)
        vm.startObserving()
        await waitFor { vm.selected?.title == "First" }
        let first = try XCTUnwrap(vm.selected)

        await vm.acknowledge(first)

        // The acknowledged theme's referenced inbox item is marked read.
        let readAt = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT read_at FROM inbox_items WHERE id = ?", arguments: [inboxID])
        }
        XCTAssertFalse((readAt ?? "").isEmpty, "referenced inbox item is marked read")

        // Selection advances to the next pending theme.
        await waitFor { vm.selected?.title == "Second" }
        XCTAssertEqual(vm.selected?.title, "Second", "selection advances to next pending theme")
    }
}
