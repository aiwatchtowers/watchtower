import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - DashboardViewModel Tests

@MainActor
final class DashboardViewModelTests: XCTestCase {
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

    // MARK: - load()

    func testLoadReturnsOpenSituationsRankedAndOpenCount() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertSituation(db, title: "Low rank", status: "open", rank: 1)
            try TestDatabase.insertSituation(db, title: "High rank", status: "open", rank: 9)
            try TestDatabase.insertSituation(db, title: "Done, excluded", status: "done", rank: 20)
        }

        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.situations.map(\.title), ["High rank", "Low rank"])
        XCTAssertEqual(vm.openCount, 2)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadOnEmptyDBYieldsEmptyFeedAndZeroCount() throws {
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.situations.isEmpty)
        XCTAssertEqual(vm.openCount, 0)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - loadMore() pagination

    func testLoadMoreAppendsNextPage() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertSituation(db, title: "A", rank: 3)
            try TestDatabase.insertSituation(db, title: "B", rank: 2)
            try TestDatabase.insertSituation(db, title: "C", rank: 1)
        }

        let vm = DashboardViewModel(dbManager: dbManager)
        vm.pageSize = 2
        vm.load()
        XCTAssertEqual(vm.situations.map(\.title), ["A", "B"])

        vm.loadMore()
        XCTAssertEqual(vm.situations.map(\.title), ["A", "B", "C"])
    }

    // MARK: - done / dismiss / snooze flip status and reload

    func testDoneMarksSituationDoneAndRemovesItFromTheOpenFeed() throws {
        let id = try dbManager.dbPool.write { try TestDatabase.insertSituation($0, status: "open") }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        let situation = try XCTUnwrap(vm.situations.first)

        vm.done(situation)

        XCTAssertTrue(vm.situations.isEmpty)
        XCTAssertEqual(vm.openCount, 0)
        let status = try dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM situations WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(status, "done")
    }

    func testDismissMarksSituationDismissedAndRemovesItFromTheOpenFeed() throws {
        try dbManager.dbPool.write { try TestDatabase.insertSituation($0, status: "open") }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        let situation = try XCTUnwrap(vm.situations.first)

        vm.dismiss(situation)

        XCTAssertTrue(vm.situations.isEmpty)
        XCTAssertEqual(vm.openCount, 0)
    }

    func testSnoozeMarksSituationSnoozedAndRemovesItFromTheOpenFeed() throws {
        try dbManager.dbPool.write { try TestDatabase.insertSituation($0, status: "open") }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        let situation = try XCTUnwrap(vm.situations.first)

        vm.snooze(situation, until: "2026-08-01T00:00:00Z")

        XCTAssertTrue(vm.situations.isEmpty)
        let (status, until) = try dbManager.dbPool.read { db -> (String, String) in
            let row = try Row.fetchOne(db, sql: "SELECT status, snooze_until FROM situations WHERE id = ?", arguments: [situation.id])!
            return (row["status"] as String, row["snooze_until"] as String)
        }
        XCTAssertEqual(status, "snoozed")
        XCTAssertEqual(until, "2026-08-01T00:00:00Z")
    }

    // MARK: - feedback

    func testSubmitFeedbackNegativeOneCreatesLearnedRuleAndReloads() throws {
        try dbManager.dbPool.write { db in
            let situationID = try TestDatabase.insertSituation(db, status: "open")
            let item = try TestDatabase.insertInboxItem(db, channelID: "C-alpha")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item)
        }
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.load()
        let situation = try XCTUnwrap(vm.situations.first)

        vm.submitFeedback(situation, rating: -1)

        let ruleCount = try dbManager.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = 'channel:C-alpha'") ?? 0
        }
        XCTAssertEqual(ruleCount, 1)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - loadMemberSignals

    func testLoadMemberSignalsReturnsJoinedItemsOrderedByMessageTS() throws {
        let situationID = try dbManager.dbPool.write { db -> Int64 in
            let situationID = try TestDatabase.insertSituation(db)
            let item2 = try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000200.000000", snippet: "second")
            let item1 = try TestDatabase.insertInboxItem(db, channelID: "C1", messageTS: "1700000100.000000", snippet: "first")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item2)
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: item1)
            return situationID
        }

        let vm = DashboardViewModel(dbManager: dbManager)
        let members = vm.loadMemberSignals(Int(situationID))

        XCTAssertEqual(members.map(\.snippet), ["first", "second"])
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadMemberSignalsEmptyWhenNoLinks() throws {
        let situationID = try dbManager.dbPool.write { try TestDatabase.insertSituation($0) }
        let vm = DashboardViewModel(dbManager: dbManager)

        let members = vm.loadMemberSignals(Int(situationID))

        XCTAssertTrue(members.isEmpty)
    }
}
