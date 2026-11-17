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
        let message = try XCTUnwrap(vm.errorMessage)
        XCTAssertTrue(message.hasPrefix(PeopleCardCopy.actionFailed(stopping: true, "")), message)
        XCTAssertFalse(vm.isCardStopped("1:UDANA"))
        XCTAssertNotNil(vm.cardFor(userID: "1:UDANA"), "the card is still shown")
    }

    /// No CLI binary: nothing runs, the card stays and the view says why.
    func testStopCardWithoutCLIKeepsCard() async {
        let vm = PeopleViewModel(dbManager: dbManager, cliRunner: nil)
        vm.load()

        await vm.stopCard(userID: "1:UDANA")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotNil(vm.cardFor(userID: "1:UDANA"))
    }
}
