import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A scripted `confluence` CLI for the connect sheet (#573): `access --json`
/// answers `read`, `select --recent` writes `selectKeys` as ext_sources rows
/// for the named account (or fails with `selectError`).
private final class ConnectCLI: CLIRunnerProtocol, @unchecked Sendable {
    let pool: DatabasePool
    var read = true
    /// Replaces `access --json`'s answer when set (an undecodable one).
    var accessBody: String?
    var selectKeys: [String] = []
    var selectError: String?
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.withLock { recorded } }

    init(pool: DatabasePool) { self.pool = pool }

    func run(args: [String]) async throws -> Data {
        lock.withLock { recorded.append(args) }
        switch args.last {
        case "--json":
            return Data((accessBody ?? #"{"read":\#(read),"write":false}"#).utf8)
        case "--recent":
            if let selectError { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "log line\n\(selectError)") }
            let account = Int64(args[2]) ?? 0
            let keys = selectKeys
            try await pool.write { db in
                for key in keys {
                    try TestDatabase.insertExtSource(db, jiraAccountID: account, containerKey: key, containerName: "Space \(key)")
                }
            }
            return Data()
        default:
            return Data()
        }
    }

    func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
}

@MainActor
final class ConfluenceConnectSelectionTests: XCTestCase {
    private var pool: DatabasePool!
    private var cli: ConnectCLI!
    /// The site the "connect" added, and the ids read before it.
    private var added = 0
    private var before: Set<Int> = []

    override func setUp() async throws {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        pool = manager.dbPool
        cli = ConnectCLI(pool: pool)
        let existing = try await pool.write { db in try TestDatabase.insertJiraAccount(db, cloudID: "old") }
        before = [Int(existing)]
        added = Int(try await pool.write { db in try TestDatabase.insertJiraAccount(db, cloudID: "new") })
    }

    private func run(featureOff: Bool = false, before: Set<Int>?) async -> ConfluenceConnectSelection {
        let selection = ConfluenceConnectSelection(dbPool: pool, runner: cli) { featureOff }
        await selection.run(accountIDsBefore: before)
        return selection
    }

    func testSelectsRecentSpacesOfTheAddedSiteOnly() async {
        cli.selectKeys = ["ENG", "OPS"]
        let selection = await run(before: before)
        XCTAssertEqual(cli.calls, [
            ["confluence", "--account", String(added), "access", "--json"],
            ["confluence", "--account", String(added), "select", "--recent"]
        ])
        XCTAssertEqual(
            selection.line,
            "Confluence: syncing 2 spaces you work in — Space ENG, Space OPS. Choose more in Settings → Connections → Jira."
        )
    }

    func testRunsOnce() async {
        let selection = await run(before: before)
        await selection.run(accountIDsBefore: before)
        XCTAssertEqual(cli.calls.count, 2)
    }

    // F4: the manual twin's gate — nothing runs while Confluence in search is off.
    func testFeatureOffSelectsNothing() async {
        let selection = await run(featureOff: true, before: before)
        XCTAssertTrue(cli.calls.isEmpty)
        XCTAssertEqual(selection.line, "Turn on Confluence in search (Settings → Features) to sync your spaces.")
    }

    // F1: a grant without the Confluence scopes (refused and retried Jira-only,
    // or quietly dropped) is said in words; no select, no Grant loop.
    func testGrantWithoutConfluenceSaysSoAndSelectsNothing() async {
        cli.read = false
        let selection = await run(before: before)
        XCTAssertEqual(cli.calls.map(\.last), ["--json"])
        XCTAssertEqual(selection.line, "Jira connected; Confluence isn't enabled for this Atlassian app.")
    }

    func testFailureIsPlainWords() async {
        cli.selectError = "Error: Confluence access not granted — run: watchtower jira login --account 2 --with-confluence"
        let selection = await run(before: before)
        XCTAssertEqual(
            selection.line,
            "Confluence: couldn't choose spaces (Confluence access isn't granted). Choose them in Settings → Connections → Jira."
        )
        XCTAssertFalse(selection.line?.contains("watchtower") ?? true, "no raw CLI command")
    }

    // F15: undecodable access output is a sentence, not a DecodingError.
    func testUndecodableAccessIsPlainWords() async {
        cli.accessBody = "not json"
        let selection = await run(before: before)
        XCTAssertEqual(cli.calls.map(\.last), ["--json"])
        XCTAssertEqual(
            selection.line,
            "Confluence: couldn't choose spaces (couldn't read Confluence access). Choose them in Settings → Connections → Jira."
        )
    }

    func testNoAddedSiteSelectsNowhere() async {
        let selection = await run(before: nil)
        XCTAssertTrue(cli.calls.isEmpty)
        XCTAssertEqual(selection.line, "Confluence: choose spaces in Settings → Connections → Jira.")
    }

    func testNoneFound() async {
        let selection = await run(before: before)
        XCTAssertEqual(
            selection.line,
            "Confluence: no space you wrote in or viewed in the last 90 days. Choose spaces in Settings → Connections → Jira."
        )
    }
}
