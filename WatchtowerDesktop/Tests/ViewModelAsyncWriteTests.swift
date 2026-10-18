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
        let running = await boundedValue(Task { true }, timeout: .seconds(1))
        XCTAssertEqual(running, true, "the main actor runs while both saves wait")
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
        try await dbManager.dbPool.write {
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
