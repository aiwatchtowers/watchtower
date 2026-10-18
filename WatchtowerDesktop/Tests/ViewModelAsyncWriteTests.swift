import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Board #670 phase 2: view model writes wait on GRDB's writer queue, not
/// on the main thread. Each test holds the writer from another thread, as a
/// busy database would, and checks the rules: the state changes only once
/// the write landed, a second press meanwhile does nothing, and saves that
/// must stay in order do.
@MainActor
final class ViewModelAsyncWriteTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    func testPendingWritesRunsOneBodyPerKey() async {
        let pending = PendingWrites()
        let gate = AsyncGate()
        let first = Task { await pending.run("k") { await gate.wait(); return 1 } }
        let entered = await eventually { pending.isPending("k") }
        XCTAssertTrue(entered)
        let second = await pending.run("k") { 2 }
        XCTAssertNil(second, "a second run under the same key does nothing")
        let other = await pending.run("other") { 3 }
        XCTAssertEqual(other, 3, "another key is not blocked")
        gate.release()
        let firstValue = await first.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertFalse(pending.isPending("k"))
    }

    /// A slow body asked for first still finishes before a fast one asked
    /// for after it: without the chain the fast one would land first.
    func testSerialWritesRunInTheOrderAskedFor() async {
        let writes = SerialWrites()
        let gate = AsyncGate()
        var order: [String] = []
        let slow = Task { await writes.run { await gate.wait(); order.append("first") } }
        let fast = Task { await writes.run { order.append("second") } }
        let queued = await eventually { writes.depth == 2 }
        XCTAssertTrue(queued)
        let early: Void? = await boundedValue(Task { () }, timeout: .seconds(1))
        XCTAssertNotNil(early)
        XCTAssertEqual(order, [], "the second body waits for the first")
        gate.release()
        await slow.value
        await fast.value
        XCTAssertEqual(order, ["first", "second"])
        XCTAssertEqual(writes.depth, 0)
    }

    /// A failed body does not stop the chain.
    func testSerialWritesGoOnAfterAFailure() async {
        struct Refused: Error {}
        let writes = SerialWrites()
        let failed = try? await writes.runThrowing { () throws -> Int in throw Refused() }
        XCTAssertNil(failed)
        let next = await writes.run { 7 }
        XCTAssertEqual(next, 7)
    }

    /// A sub-item toggle re-reads the row in its own transaction: another
    /// item checked elsewhere after the list loaded stays checked.
    func testTrackSubItemToggleKeepsAnotherItemChangedMeanwhile() async throws {
        let items = #"[{"text":"one","status":"open"},{"text":"two","status":"open"}]"#
        let id = try await dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            return try TestDatabase.insertTrack(db, text: "two items", subItems: items)
        }
        let vm = TracksViewModel(dbManager: dbManager)
        vm.load()
        let shown = try XCTUnwrap((vm.updatedTracks + vm.allTracks).first { Int64($0.id) == id })
        try await dbManager.dbPool.write { db in
            let done = #"[{"text":"one","status":"open"},{"text":"two","status":"done"}]"#
            try db.execute(sql: "UPDATE tracks SET sub_items = ? WHERE id = ?", arguments: [done, id])
        }

        await vm.toggleSubItem(shown, at: 0)

        XCTAssertNil(vm.errorMessage)
        let stored = try await dbManager.dbPool.read { db in
            try TrackQueries.fetchByID(db, id: Int(id))?.decodedSubItems.map(\.status)
        }
        XCTAssertEqual(stored, ["done", "done"])
    }

    /// A failed archive says so and leaves the selection where it was.
    func testArchiveFailureKeepsTheSelection() async throws {
        let history = ChatHistoryViewModel(dbManager: dbManager, attachmentsRoot: nil)
        history.selectedConversationID = 999
        let archived = await history.archive(999)
        XCTAssertFalse(archived)
        XCTAssertNotNil(history.lastError)
        XCTAssertEqual(history.selectedConversationID, 999)
    }

    /// The star shows only once it is stored, and a second press while the
    /// write waits does not flip it back.
    func testChannelStarWhileTheWriterIsBusy() async throws {
        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@example.com")
        }
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }
        let first = Task { await vm.toggleStarredChannel("1:C1") }
        let pending = await eventually { vm.pendingWrites.isPending("star:1:C1") }
        XCTAssertTrue(pending, "the main actor runs while the write waits")
        XCTAssertFalse(vm.isChannelStarred("1:C1"), "the star waits for its write")
        let second: Void? = await boundedValue(Task { await vm.toggleStarredChannel("1:C1") })
        XCTAssertNotNil(second, "a second press returns at once")
        held.release()
        let done: Void? = await boundedValue(first)
        XCTAssertNotNil(done)
        XCTAssertTrue(vm.isChannelStarred("1:C1"))
        XCTAssertNil(vm.errorMessage)
        vm.load()
        XCTAssertTrue(vm.isChannelStarred("1:C1"), "starred once, not toggled twice")
    }

    /// A failed star write leaves the star as it was and says why.
    func testChannelStarFailureKeepsTheStar() async throws {
        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@example.com")
            try db.execute(sql: """
                CREATE TRIGGER refuse_profiles BEFORE INSERT ON user_profile
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
        let vm = DigestViewModel(dbManager: dbManager)
        vm.load()
        await vm.toggleStarredChannel("1:C1")
        XCTAssertFalse(vm.isChannelStarred("1:C1"))
        XCTAssertNotNil(vm.errorMessage)

        // The next star that lands clears the banner.
        try await dbManager.dbPool.write { try $0.execute(sql: "DROP TRIGGER refuse_profiles") }
        await vm.toggleStarredChannel("1:C1")
        XCTAssertTrue(vm.isChannelStarred("1:C1"))
        XCTAssertNil(vm.errorMessage)
    }

    /// Two connection saves while the writer is busy land in order: the
    /// newer pick is what stays.
    func testConnectionSavesLandInOrder() async throws {
        try await dbManager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@example.com")
            try TestDatabase.insertProfile(db, slackUserID: "google:me@example.com", role: "EM")
        }
        let vm = PeopleViewModel(dbManager: dbManager)
        vm.load()
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }
        let older = Task { await vm.updateConnections(reports: [], peers: [], manager: "U-old") }
        let newer = Task { await vm.updateConnections(reports: [], peers: [], manager: "U-new") }
        let queued = await eventually { vm.writes.depth == 2 }
        XCTAssertTrue(queued, "both saves wait in the chain, the newer behind the older")
        held.release()
        let olderDone: Void? = await boundedValue(older)
        let newerDone: Void? = await boundedValue(newer)
        XCTAssertNotNil(olderDone)
        XCTAssertNotNil(newerDone)
        let manager = try await dbManager.dbPool.read {
            try String.fetchOne($0, sql: "SELECT manager FROM user_profile")
        }
        XCTAssertEqual(manager, "U-new")
        XCTAssertEqual(vm.currentProfile?.manager, "U-new")
    }

    /// Convert to Target pressed twice while the writer is busy makes one
    /// target.
    func testConvertToTargetTwiceWhileTheWriterIsBusyMakesOneTarget() async throws {
        _ = try await dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, title: "Adopt the flow", essence: "Cuts drop-off", status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.registryItems.first)
        let held = HeldWriter(dbManager.dbPool)
        defer { held.release() }
        let first = Task { await vm.convertToTarget(idea) }
        let pending = await eventually { vm.pendingWrites.isPending("convert:\(idea.id)") }
        XCTAssertTrue(pending)
        let second = await boundedValue(Task { await vm.convertToTarget(idea) })
        XCTAssertEqual(second, .some(nil), "a second press returns at once and converts nothing")
        held.release()
        let created = await boundedValue(first)
        XCTAssertNotNil(created.flatMap { $0 })
        let targets = try await dbManager.dbPool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM targets WHERE source_type = 'idea'")
        }
        XCTAssertEqual(targets, 1)
    }
}
