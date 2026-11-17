import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Stop card for this person / Make cards again (#1769, A14): the view model
/// runs `watchtower people exclude|include` and shows what the database then
/// holds. No process is spawned: the runner stands in for the CLI.
@MainActor
final class PeopleViewModelStopCardTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
            try dbManager.dbPool.write { db in
                try TestDatabase.insertPeopleCard(db, userID: "1:UDANA")
            }
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    /// Records the argv and, like the CLI, writes the exclusion before it
    /// answers; or throws.
    private final class PeopleCLIStandIn: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        private let pool: DatabasePool
        private let failure: Error?

        init(pool: DatabasePool, failure: Error? = nil) {
            self.pool = pool
            self.failure = failure
        }

        var argsSeen: [[String]] { lock.withLock { calls } }

        func run(args: [String]) async throws -> Data {
            lock.withLock { calls.append(args) }
            if let failure { throw failure }
            let userID = args[3]
            let excluded = args[1] == "exclude"
            try await pool.write { db in
                if excluded {
                    try db.execute(sql: "INSERT OR IGNORE INTO people_card_exclusions (user_id) VALUES (?)",
                                   arguments: [userID])
                    try db.execute(sql: "DELETE FROM people_cards WHERE user_id = ?", arguments: [userID])
                } else {
                    try db.execute(sql: "DELETE FROM people_card_exclusions WHERE user_id = ?", arguments: [userID])
                }
            }
            return Data(#"{"ok":true,"user_id":"\#(userID)","excluded":\#(excluded)}"#.utf8)
        }
    }

    func testStopCardRunsCLIAndReloads() async throws {
        let runner = PeopleCLIStandIn(pool: dbManager.dbPool)
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        XCTAssertNotNil(vm.cardFor(userID: "1:UDANA"))
        XCTAssertFalse(vm.isCardStopped("1:UDANA"))

        await vm.stopCard(userID: "1:UDANA")

        XCTAssertEqual(runner.argsSeen, [["people", "exclude", "--user", "1:UDANA", "--json"]])
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.cardActionError(for: "1:UDANA"))
        XCTAssertEqual(vm.stoppedPeople, ["1:UDANA"], "the stopped person stays reachable from the list")
        XCTAssertTrue(vm.isCardStopped("1:UDANA"), "the person shows the stopped state")
        XCTAssertNil(vm.cardFor(userID: "1:UDANA"))
    }

    func testMakeCardsAgainRunsInclude() async throws {
        let runner = PeopleCLIStandIn(pool: dbManager.dbPool)
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        await vm.stopCard(userID: "1:UDANA")

        await vm.makeCardsAgain(userID: "1:UDANA")

        XCTAssertEqual(runner.argsSeen.last, ["people", "include", "--user", "1:UDANA", "--json"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isCardStopped("1:UDANA"))
    }

    func testStopCardFailureKeepsCard() async throws {
        let runner = PeopleCLIStandIn(
            pool: dbManager.dbPool,
            failure: CLIRunnerError.nonZeroExit(code: 1, stderr: "user not found")
        )
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()

        await vm.stopCard(userID: "1:UDANA")

        XCTAssertEqual(runner.argsSeen.count, 1)
        let message = try XCTUnwrap(vm.cardActionError(for: "1:UDANA"), "shown on the person view")
        XCTAssertNil(vm.cardActionError(for: "1:ULEE"), "only on that person's view")
        XCTAssertTrue(message.hasPrefix(PeopleCardCopy.actionFailed(stopping: true, "")), message)
        XCTAssertFalse(vm.isCardStopped("1:UDANA"))
        XCTAssertNotNil(vm.cardFor(userID: "1:UDANA"), "the card is still shown")
    }

    /// No CLI binary: nothing runs, the card stays and the view says why.
    func testStopCardWithoutCLIKeepsCard() async {
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: nil)
        vm.load()

        await vm.stopCard(userID: "1:UDANA")

        XCTAssertNotNil(vm.cardActionError(for: "1:UDANA"))
        XCTAssertNotNil(vm.cardFor(userID: "1:UDANA"))
    }

    /// A failed Make cards again with no card left: the person is still
    /// stopped and listed, and the error stays on their view (a load does
    /// not clear it).
    func testMakeCardsAgainFailureKeepsStoppedAndError() async throws {
        try await dbManager.dbPool.write { db in
            try db.execute(sql: "DELETE FROM people_cards")
            try db.execute(sql: "INSERT INTO people_card_exclusions (user_id) VALUES ('1:UDANA')")
        }
        let runner = PeopleCLIStandIn(
            pool: dbManager.dbPool,
            failure: CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked")
        )
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        XCTAssertEqual(vm.stoppedPeople, ["1:UDANA"])

        await vm.makeCardsAgain(userID: "1:UDANA")
        vm.load()

        XCTAssertTrue(vm.isCardStopped("1:UDANA"))
        XCTAssertNil(vm.errorMessage, "not the list's load error, so no Retry swallows it")
        let message = try XCTUnwrap(vm.cardActionError(for: "1:UDANA"))
        XCTAssertTrue(message.hasPrefix(PeopleCardCopy.actionFailed(stopping: false, "")), message)
    }

    /// Stopping a card while an older window is shown keeps that window.
    func testStopCardKeepsSelectedWindow() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "1:ULEE", periodFrom: 100, periodTo: 200)
            try TestDatabase.insertPeopleCard(db, userID: "1:USAM", periodFrom: 100, periodTo: 200)
        }
        let runner = PeopleCLIStandIn(pool: dbManager.dbPool)
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        XCTAssertEqual(vm.availableWindows.count, 2)
        vm.loadWindow(at: 1)
        XCTAssertEqual(Set(vm.cards.map(\.userID)), ["1:ULEE", "1:USAM"])

        await vm.stopCard(userID: "1:ULEE")

        XCTAssertEqual(vm.selectedWindow, 1)
        XCTAssertEqual(vm.availableWindows[vm.selectedWindow].to, 200)
        XCTAssertEqual(vm.cards.map(\.userID), ["1:USAM"])
    }

    /// The shown window is gone after the reload: selection and data reset
    /// to the newest window together.
    func testStopCardResetsVanishedWindow() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertPeopleCard(db, userID: "1:ULEE", periodFrom: 100, periodTo: 200)
        }
        let runner = PeopleCLIStandIn(pool: dbManager.dbPool)
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: runner)
        vm.load()
        vm.loadWindow(at: 1)

        await vm.stopCard(userID: "1:ULEE")

        XCTAssertEqual(vm.availableWindows.count, 1)
        XCTAssertEqual(vm.selectedWindow, 0)
        XCTAssertEqual(vm.cards.map(\.userID), ["1:UDANA"])
    }
}

/// Edit Connections offers everyone already linked, card or not, so a link
/// to a stopped person can still be removed (#1769).
final class PeopleEditConnectionsChoicesTests: XCTestCase {
    func testChoicesKeepLinkedPeopleWithoutCards() {
        let profile = UserProfile(
            slackUserID: "1:UOWNER", reports: #"["1:UREP"]"#, peers: #"["1:UDANA","1:USAM"]"#, manager: "1:ULEE"
        )
        let choices = EditConnectionsSheet.choices(cards: [], profile: profile)
        XCTAssertEqual(Set(choices), ["1:ULEE", "1:UDANA", "1:USAM", "1:UREP"])
        XCTAssertEqual(choices.count, 4)
    }

    func testChoicesWithoutProfileAreTheCards() {
        XCTAssertEqual(EditConnectionsSheet.choices(cards: [], profile: nil), [])
    }
}
