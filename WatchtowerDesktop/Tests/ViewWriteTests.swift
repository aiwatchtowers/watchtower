import XCTest
import GRDB
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Board #590: the write-then-update pattern every view write follows
/// (`ViewWrite.run`) — state changes only after the write commits, a failure
/// keeps the owner's draft or toggle, and one pending write per action.
@MainActor
final class ViewWriteTests: XCTestCase {
    /// A view's `@State`, as a reference the closures and a `Binding` share
    /// (touched only on the main actor, hence unchecked).
    private final class ViewState: @unchecked Sendable {
        var draft = "typed by the owner"
        var collecting = true
        var pending = false
        var error: String?
        var pendingBinding: Binding<Bool> {
            Binding(get: { self.pending }, set: { self.pending = $0 })
        }
    }

    nonisolated private static let insertChannel = "INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')"

    func testSuccessChangesStateOnlyOnceTheWriteCommitted() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let state = ViewState()
        var committedBeforeUpdate = false

        let ran = await ViewWrite.run(manager.dbPool, pending: state.pendingBinding, { db in
            try db.execute(sql: Self.insertChannel)
        }, onSuccess: {
            committedBeforeUpdate = (try? manager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM channels") }) == 1
            state.draft = ""
        }, onFailure: { state.error = $0.localizedDescription })

        XCTAssertTrue(ran)
        XCTAssertTrue(committedBeforeUpdate, "the state update sees the committed row")
        XCTAssertEqual(state.draft, "", "the draft clears on success")
        XCTAssertNil(state.error)
        XCTAssertFalse(state.pending)
    }

    /// The meeting-notes / Quick Capture shape: a failed insert keeps what
    /// the owner typed.
    func testFailureKeepsTheDraft() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let state = ViewState()

        let ran = await ViewWrite.run(manager.dbPool, pending: state.pendingBinding, { db in
            try db.execute(sql: "INSERT INTO no_such_table (x) VALUES (1)")
        }, onSuccess: { state.draft = "" }, onFailure: { state.error = $0.localizedDescription })

        XCTAssertFalse(ran)
        XCTAssertEqual(state.draft, "typed by the owner", "nothing typed is lost")
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.pending, "the next submit is allowed again")
    }

    /// The track pane's shape: a toggle on a watch deleted elsewhere stays
    /// where it was.
    func testFailureKeepsTheToggle() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let state = ViewState()

        await ViewWrite.run(manager.dbPool, { db in
            try TrackQueries.setEnabled(db, id: 4242, enabled: false)
        }, onSuccess: { state.collecting = false }, onFailure: { state.error = $0.localizedDescription })

        XCTAssertTrue(state.collecting, "the toggle stays on")
        XCTAssertNotNil(state.error)
    }

    /// While another process holds the write lock, the main actor keeps
    /// running, a second press does nothing, and one row lands on release.
    func testOnePendingWriteAtATimeWhileTheDatabaseIsLocked() async throws {
        let (seedPool, path) = try TestDatabase.createPool()
        try seedPool.close()
        defer { TestDatabase.cleanup(path: path) }
        let manager = try DatabaseManager(path: path)
        var holderConfig = Configuration()
        holderConfig.allowsUnsafeTransactions = true
        let holder = try DatabaseQueue(path: path, configuration: holderConfig)
        try await holder.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        let state = ViewState()

        let first = Task {
            await ViewWrite.run(manager.dbPool, pending: state.pendingBinding, { db in
                try db.execute(sql: Self.insertChannel)
            }, onSuccess: { state.draft = "" }, onFailure: { state.error = $0.localizedDescription })
        }
        let start = Date()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "the main actor kept running while the write waited")
        XCTAssertTrue(state.pending)
        XCTAssertEqual(state.draft, "typed by the owner", "nothing changes before the write lands")

        var secondRan = false
        let second = await ViewWrite.run(manager.dbPool, pending: state.pendingBinding, { db in
            try db.execute(sql: Self.insertChannel)
        }, onSuccess: { secondRan = true }, onFailure: { _ in secondRan = true })
        XCTAssertFalse(second)
        XCTAssertFalse(secondRan, "a press while one write is pending does nothing")

        try await holder.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        let firstRan = await first.value
        XCTAssertTrue(firstRan)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.draft, "")
        XCTAssertFalse(state.pending)
        let count = try await manager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM channels") }
        XCTAssertEqual(count, 1)
    }
}
