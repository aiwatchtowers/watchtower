import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A scripted `confluence` CLI: answers `spaces --json` with a canned list,
/// and `select`/`unselect` by writing the same `ext_sources` rows the real
/// CLI writes — so the VM's reload after a command sees real DB state. Any
/// command can be made to fail with a stderr text, and `select` can be held
/// on a gate to model a call still running when the view goes away.
private final class ScriptedConfluenceCLI: CLIRunnerProtocol, @unchecked Sendable {
    let pool: DatabasePool
    var spacesJSON = "[]"
    var spacesError: String?
    var selectError: String?
    private(set) var invocations: [[String]] = []

    private let lock = NSLock()
    private var gateArmed = false
    private var gateWaiter: CheckedContinuation<Void, Never>?
    private var gateOpen = false

    init(pool: DatabasePool) { self.pool = pool }

    func armSelectGate() { gateArmed = true }

    func openSelectGate() {
        lock.lock()
        gateOpen = true
        let waiter = gateWaiter
        gateWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func run(args: [String]) async throws -> Data {
        lock.lock()
        invocations.append(args)
        lock.unlock()
        guard args.first == "confluence", args.count >= 2 else { return Data() }
        switch args[1] {
        case "spaces":
            if let spacesError { throw CLIRunnerError.nonZeroExit(code: 1, stderr: spacesError) }
            return Data(spacesJSON.utf8)
        case "select":
            if gateArmed { await waitForGate() }
            if let selectError { throw CLIRunnerError.nonZeroExit(code: 1, stderr: selectError) }
            let account = Self.account(in: args)
            try await pool.write { db in
                for key in Self.keys(in: args) {
                    try TestDatabase.insertExtSource(db, jiraAccountID: account, containerKey: key, containerName: key)
                }
            }
            return Data("Selected\n".utf8)
        case "unselect":
            let account = Self.account(in: args)
            try await pool.write { db in
                for key in Self.keys(in: args) {
                    try db.execute(
                        sql: "DELETE FROM ext_sources WHERE jira_account_id = ? AND container_key = ?",
                        arguments: [account, key]
                    )
                }
            }
            return Data()
        default:
            return Data()
        }
    }

    private func waitForGate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if gateOpen {
                lock.unlock()
                continuation.resume()
            } else {
                gateWaiter = continuation
                lock.unlock()
            }
        }
    }

    private static func account(in args: [String]) -> Int64 {
        guard let idx = args.firstIndex(of: "--account"), idx + 1 < args.count else { return 0 }
        return Int64(args[idx + 1]) ?? 0
    }

    /// The positional space keys after `confluence select|unselect`.
    private static func keys(in args: [String]) -> [String] {
        var out: [String] = []
        var skipNext = false
        for arg in args.dropFirst(2) {
            if skipNext { skipNext = false; continue }
            if arg == "--account" { skipNext = true; continue }
            out.append(arg)
        }
        return out
    }
}

@MainActor
final class ConfluenceSpacesViewModelTests: XCTestCase {
    private var path = ""

    override func tearDownWithError() throws {
        if !path.isEmpty { TestDatabase.cleanup(path: path) }
        try super.tearDownWithError()
    }

    private func makeManager() throws -> DatabaseManager {
        let (manager, dbPath) = try TestDatabase.createDatabaseManager()
        path = dbPath
        return manager
    }

    private static let consentMessage =
        "Confluence access not granted — run: watchtower jira login --account 1 --with-confluence"

    private static let twoSpaces = """
        [{"key":"OPS","name":"Операції","id":"98305","selected":true},\
        {"key":"ENG","name":"Engineering","id":"65537","selected":false}]
        """

    // MARK: - load

    func testLoadMergesLiveSpacesWithDBStatuses() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db -> Int64 in
            let acct = try TestDatabase.insertJiraAccount(db, siteName: "Acme")
            let src = try TestDatabase.insertExtSource(
                db, jiraAccountID: acct, containerKey: "OPS", containerName: "Операції",
                status: "error", error: "HTTP 500 from /wiki/api/v2/pages?limit=100",
                backfillDone: true, lastSyncedAt: "2026-09-20T10:00:00Z"
            )
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "1", kind: "page")
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "2", kind: "blogpost")
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "att3", kind: "attachment")
            return acct
        }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        await vm.load()

        XCTAssertEqual(cli.invocations.first, ["confluence", "spaces", "--account", String(acct), "--json"])
        XCTAssertFalse(vm.needsConsent)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.spaces.map(\.key), ["ENG", "OPS"], "sorted by name")
        let eng = try XCTUnwrap(vm.spaces.first { $0.key == "ENG" })
        XCTAssertFalse(eng.selected)
        XCTAssertEqual(eng.docCount, 0)
        let ops = try XCTUnwrap(vm.spaces.first { $0.key == "OPS" })
        XCTAssertTrue(ops.selected)
        XCTAssertEqual(ops.name, "Операції")
        XCTAssertEqual(ops.status, "error")
        XCTAssertEqual(ops.error, "HTTP 500 from /wiki/api/v2/pages?limit=100")
        XCTAssertEqual(ops.docCount, 3)
        XCTAssertTrue(ops.backfillDone)
        XCTAssertEqual(ops.lastSyncedAt, "2026-09-20T10:00:00Z")
    }

    /// Selection truth is the DB (what the daemon syncs), not the CLI's
    /// `selected` flag; a selected space missing from the live list (deleted
    /// on the site, or its key changed) still shows so it can be unselected.
    func testLoadKeepsSelectedSpaceMissingFromLiveList() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db -> Int64 in
            let acct = try TestDatabase.insertJiraAccount(db)
            try TestDatabase.insertExtSource(db, jiraAccountID: acct, containerKey: "GONE", containerName: "Archived")
            return acct
        }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = #"[{"key":"ENG","name":"Engineering","id":"1","selected":false}]"#
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        await vm.load()

        XCTAssertEqual(vm.spaces.map(\.key), ["GONE", "ENG"], "Archived sorts before Engineering")
        XCTAssertEqual(vm.spaces.first { $0.key == "GONE" }?.selected, true)
    }

    func testLoadEmptyLiveListDecodes() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = "[]\n"
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        await vm.load()

        XCTAssertTrue(vm.spaces.isEmpty)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.needsConsent)
    }

    func testLoadConsentMessageSetsNeedsConsent() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesError = Self.consentMessage
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        await vm.load()

        XCTAssertTrue(vm.needsConsent)
        XCTAssertEqual(vm.consentMessage, Self.consentMessage)
        XCTAssertNil(vm.errorMessage, "consent is its own state, not a red error")
        XCTAssertFalse(vm.isLoading)
    }

    /// The CLI prints its error as the LAST stderr line, after any log lines
    /// the command wrote (cmd/root.go): the consent hint is found there and
    /// shown without the log noise.
    func testConsentHintAfterLogLinesIsRecognized() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesError = "2026/09/27 10:00:00 jira: refreshing token\n" + Self.consentMessage
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        await vm.load()

        XCTAssertTrue(vm.needsConsent)
        XCTAssertEqual(vm.consentMessage, Self.consentMessage)
    }

    func testLoadOtherFailureSetsErrorNotConsentAndKeepsDBSelections() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db -> Int64 in
            let acct = try TestDatabase.insertJiraAccount(db)
            try TestDatabase.insertExtSource(db, jiraAccountID: acct, containerKey: "ENG", containerName: "Engineering")
            return acct
        }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesError = "listing Confluence spaces: Get \"https://api.atlassian.com/ex/confluence/x/wiki/api/v2/spaces?limit=100\": dial tcp: i/o timeout"
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        await vm.load()

        XCTAssertFalse(vm.needsConsent)
        XCTAssertEqual(vm.errorMessage, cli.spacesError)
        XCTAssertEqual(vm.spaces.map(\.key), ["ENG"])
        XCTAssertEqual(vm.spaces.first?.selected, true)
    }

    func testLoadAfterConsentGrantedClearsNeedsConsent() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesError = Self.consentMessage
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()
        XCTAssertTrue(vm.needsConsent)

        cli.spacesError = nil
        cli.spacesJSON = Self.twoSpaces
        await vm.load()

        XCTAssertFalse(vm.needsConsent)
        XCTAssertNil(vm.consentMessage)
        XCTAssertEqual(vm.spaces.count, 2)
    }

    func testLoadWithoutCLIReportsError() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: nil)

        await vm.load()

        XCTAssertEqual(vm.errorMessage, "Watchtower CLI not found")
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - setSelected

    func testSetSelectedRunsSelectThenReloads() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()

        await vm.setSelected("ENG", true)

        XCTAssertTrue(cli.invocations.contains(["confluence", "select", "ENG", "--account", String(acct)]))
        XCTAssertEqual(cli.invocations.last?[1], "spaces", "reloads after the command")
        let eng = try XCTUnwrap(vm.spaces.first { $0.key == "ENG" })
        XCTAssertTrue(eng.selected)
        XCTAssertEqual(eng.status, "ok")
        XCTAssertFalse(eng.backfillDone, "a fresh source reads as syncing")
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.busyKeys.isEmpty)
    }

    func testSetSelectedOffRunsUnselect() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db -> Int64 in
            let acct = try TestDatabase.insertJiraAccount(db)
            try TestDatabase.insertExtSource(db, jiraAccountID: acct, containerKey: "OPS", containerName: "Операції")
            return acct
        }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()

        await vm.setSelected("OPS", false)

        XCTAssertTrue(cli.invocations.contains(["confluence", "unselect", "OPS", "--account", String(acct)]))
        XCTAssertEqual(vm.spaces.first { $0.key == "OPS" }?.selected, false)
    }

    func testFailedSelectSetsErrorAndLeavesUnselected() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        cli.selectError = "selecting ENG: database is locked"
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()

        await vm.setSelected("ENG", true)

        XCTAssertEqual(vm.errorMessage, "selecting ENG: database is locked")
        XCTAssertEqual(vm.spaces.first { $0.key == "ENG" }?.selected, false)
        XCTAssertFalse(vm.needsConsent)
        XCTAssertTrue(vm.busyKeys.isEmpty)
        let rows = try await pool.read { db in try ExtSourceQueries.fetchForJiraAccount(db, accountID: acct) }
        XCTAssertTrue(rows.isEmpty)
    }

    func testSelectConsentFailureSetsNeedsConsent() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()
        cli.selectError = Self.consentMessage

        await vm.setSelected("ENG", true)

        XCTAssertTrue(vm.needsConsent)
        XCTAssertNil(vm.errorMessage)
    }

    /// The navigation rule: the VM is owned by AppState, keyed by Jira
    /// account id, so a select started from the Settings pane finishes (and
    /// its result is visible) after the pane is gone and re-opened.
    func testSelectSurvivesNavigationViaAppState() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        cli.armSelectGate()
        let appState = AppState()
        appState.databaseManager = manager

        var viewVM: ConfluenceSpacesViewModel? = appState.confluenceSpacesViewModel(forJiraAccount: acct, runner: cli)
        let task = Task { [weak viewVM] in await viewVM?.setSelected("ENG", true) }
        // Let the select reach the CLI, then "navigate away".
        let deadline = Date().addingTimeInterval(5)
        while !cli.invocations.contains(where: { $0.count > 1 && $0[1] == "select" }) {
            guard Date() < deadline else { return XCTFail("select never reached the CLI") }
            await Task.yield()
        }
        weak var weakVM = viewVM
        viewVM = nil
        XCTAssertNotNil(weakVM, "AppState keeps the VM alive after the view lets go")

        cli.openSelectGate()
        await task.value

        let reopened = appState.confluenceSpacesViewModel(forJiraAccount: acct, runner: cli)
        XCTAssertTrue(reopened === weakVM, "re-opening the pane gets the same VM")
        XCTAssertEqual(reopened?.spaces.first { $0.key == "ENG" }?.selected, true)
        XCTAssertTrue(reopened?.busyKeys.isEmpty ?? false)
    }

    func testAppStateVMsAreKeyedPerAccount() throws {
        let manager = try makeManager()
        let appState = AppState()
        appState.databaseManager = manager
        let cli = ScriptedConfluenceCLI(pool: manager.dbPool)

        let first = appState.confluenceSpacesViewModel(forJiraAccount: 1, runner: cli)
        let second = appState.confluenceSpacesViewModel(forJiraAccount: 2, runner: cli)

        XCTAssertNotNil(first)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second?.accountID, 2)
    }

    // MARK: - reconsent

    func testReconsentRunsTheInjectedLoginFlowThenReloads() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesError = Self.consentMessage
        var reconsentedAccounts: [Int64] = []
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli) { id in
            reconsentedAccounts.append(id)
            cli.spacesError = nil
            cli.spacesJSON = Self.twoSpaces
        }
        await vm.load()
        XCTAssertTrue(vm.needsConsent)

        await vm.reconsentAsync()

        XCTAssertEqual(reconsentedAccounts, [acct])
        XCTAssertFalse(vm.needsConsent)
        XCTAssertEqual(vm.spaces.count, 2)
    }

    // MARK: - Status line

    /// A budget-cut first sync still stamps last_synced_at: "Syncing…" wins
    /// until backfill_done flips, so an unfinished backfill never reads as done.
    func testStatusLineSyncingUntilBackfillDoneEvenWithLastSyncedAt() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z"))
        let syncing = ConfluenceSpacesViewModel.SpaceRow(
            key: "ENG", name: "Engineering", selected: true, status: "ok", error: "",
            docCount: 40, backfillDone: false, lastSyncedAt: "2026-09-27T11:00:00Z"
        )
        XCTAssertEqual(syncing.statusLine(now: now), "Syncing… · 40 documents")

        let done = ConfluenceSpacesViewModel.SpaceRow(
            key: "ENG", name: "Engineering", selected: true, status: "ok", error: "",
            docCount: 1, backfillDone: true, lastSyncedAt: "2026-09-27T11:00:00Z"
        )
        XCTAssertTrue(done.statusLine(now: now).hasPrefix("1 document · synced "), done.statusLine(now: now))

        let fresh = ConfluenceSpacesViewModel.SpaceRow(
            key: "ENG", name: "Engineering", selected: true, status: "ok", error: "",
            docCount: 0, backfillDone: false, lastSyncedAt: ""
        )
        XCTAssertEqual(fresh.statusLine(now: now), "Syncing…")

        let neverStamped = ConfluenceSpacesViewModel.SpaceRow(
            key: "ENG", name: "Engineering", selected: true, status: "ok", error: "",
            docCount: 0, backfillDone: true, lastSyncedAt: ""
        )
        XCTAssertEqual(neverStamped.statusLine(now: now), "0 documents")
    }
}
