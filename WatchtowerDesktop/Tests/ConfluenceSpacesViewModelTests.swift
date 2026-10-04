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
    /// `confluence access --json`'s answer (default: read, not write), or
    /// its failure.
    var accessJSON = #"{"read":true,"write":false}"#
    var accessError: String?
    /// Read under the lock: the tests poll these from the main actor while
    /// `run` writes them on the cooperative pool.
    var invocations: [[String]] { lock.withLock { recorded } }
    private var recorded: [[String]] = []

    private let lock = NSLock()
    private var gateArmed = false
    private var gateWaiter: CheckedContinuation<Void, Never>?
    private var gateOpen = false
    private var gateTaken = false

    /// Per-call `spaces` answers (call index → JSON; past the end,
    /// `spacesJSON`), and which calls wait for `releaseSpaces(call)`.
    var spacesQueue: [String] = []
    var gatedSpacesCalls: Set<Int> = []
    var spacesCalls: Int { lock.withLock { spacesCallCount } }
    private var spacesCallCount = 0
    private var spacesWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedSpaces: Set<Int> = []

    var selectCount: Int { invocations.filter { $0.count > 1 && $0[1] == "select" }.count }

    func releaseSpaces(_ call: Int) {
        lock.lock()
        releasedSpaces.insert(call)
        let waiter = spacesWaiters.removeValue(forKey: call)
        lock.unlock()
        waiter?.resume()
    }

    private func waitForSpacesRelease(_ call: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if releasedSpaces.contains(call) {
                lock.unlock()
                continuation.resume()
            } else {
                spacesWaiters[call] = continuation
                lock.unlock()
            }
        }
    }

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
        lock.withLock { recorded.append(args) }
        guard args.first == "confluence", args.count >= 2 else { return Data() }
        switch args[1] {
        case "spaces":
            let (call, json, gated) = lock.withLock {
                let call = spacesCallCount
                spacesCallCount += 1
                let json = call < spacesQueue.count ? spacesQueue[call] : spacesJSON
                return (call, json, gatedSpacesCalls.contains(call))
            }
            if gated { await waitForSpacesRelease(call) }
            if let spacesError { throw CLIRunnerError.nonZeroExit(code: 1, stderr: spacesError) }
            return Data(json.utf8)
        case "select":
            // Only the first select waits: a second one (a guard regression)
            // must fail the test by count, not hang it.
            let holdThisCall = lock.withLock {
                let hold = gateArmed && !gateTaken
                if hold { gateTaken = true }
                return hold
            }
            if holdThisCall { await waitForGate() }
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
        case "access":
            if let accessError { throw CLIRunnerError.nonZeroExit(code: 1, stderr: accessError) }
            return Data(accessJSON.utf8)
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

        // The load reads `confluence access` first (the Allow editing tests), then the spaces.
        XCTAssertEqual(Array(cli.invocations.prefix(2)), [
            ["confluence", "access", "--account", String(acct), "--json"],
            ["confluence", "spaces", "--account", String(acct), "--json"]
        ])
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
        let appState = AppState.isolated()
        appState.databaseManager = manager

        var syncRequests = 0
        var viewVM: ConfluenceSpacesViewModel? = appState.confluenceSpacesViewModel(forJiraAccount: acct, runner: cli) {
            syncRequests += 1
        }
        let task = Task { [weak viewVM] in await viewVM?.setSelected("ENG", true) }
        // Let the select reach the CLI, then "navigate away".
        guard await waitUntil("select call", { cli.selectCount == 1 }) else { return }
        weak var weakVM = viewVM
        viewVM = nil
        XCTAssertNotNil(weakVM, "AppState keeps the VM alive after the view lets go")

        cli.openSelectGate()
        await task.value

        let reopened = appState.confluenceSpacesViewModel(forJiraAccount: acct, runner: cli)
        XCTAssertTrue(reopened === weakVM, "re-opening the pane gets the same VM")
        XCTAssertEqual(reopened?.spaces.first { $0.key == "ENG" }?.selected, true)
        XCTAssertTrue(reopened?.busyKeys.isEmpty ?? false)
        XCTAssertEqual(syncRequests, 1, "AppState wires the injected Sync Now into the VM")
    }

    func testAppStateVMsAreKeyedPerAccount() throws {
        let manager = try makeManager()
        let appState = AppState.isolated()
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
            return nil
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

    // MARK: - Fix round 1

    /// Spins the main actor until `condition` holds (the CLI fake runs off
    /// the main actor); fails after 5 s instead of hanging.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func makeVM(
        cli: ScriptedConfluenceCLI,
        pool: DatabasePool,
        acct: Int64,
        syncRequests: @escaping @MainActor () -> Void = {}
    ) -> ConfluenceSpacesViewModel {
        ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli) { _ in nil } onSelected: {
            syncRequests()
        }
    }

    func testSuccessfulSelectRequestsOneSync() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        var syncs = 0
        let vm = makeVM(cli: cli, pool: pool, acct: acct) { syncs += 1 }
        await vm.load()

        await vm.setSelected("ENG", true)

        XCTAssertEqual(syncs, 1)
    }

    func testFailedSelectRequestsNoSync() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        cli.selectError = "selecting ENG: database is locked"
        var syncs = 0
        let vm = makeVM(cli: cli, pool: pool, acct: acct) { syncs += 1 }
        await vm.load()

        await vm.setSelected("ENG", true)

        XCTAssertEqual(syncs, 0)
    }

    func testUnselectRequestsNoSync() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db -> Int64 in
            let acct = try TestDatabase.insertJiraAccount(db)
            try TestDatabase.insertExtSource(db, jiraAccountID: acct, containerKey: "OPS", containerName: "Операції")
            return acct
        }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        var syncs = 0
        let vm = makeVM(cli: cli, pool: pool, acct: acct) { syncs += 1 }
        await vm.load()

        await vm.setSelected("OPS", false)

        XCTAssertEqual(vm.spaces.first { $0.key == "OPS" }?.selected, false)
        XCTAssertEqual(syncs, 0)
    }

    /// The older of two overlapping loads finishing first must neither clear
    /// `isLoading` under the newer one nor apply its (stale) listing.
    func testOverlappingLoadsOlderFinishingFirstIsIgnored() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesQueue = [#"[{"key":"OLD","name":"Stale","id":"1","selected":false}]"#, Self.twoSpaces]
        cli.gatedSpacesCalls = [0, 1]
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        let first = Task { await vm.load() }
        guard await waitUntil("first spaces call", { cli.spacesCalls == 1 }) else { return }
        let second = Task { await vm.load() }
        guard await waitUntil("second spaces call", { cli.spacesCalls == 2 }) else { return }

        cli.releaseSpaces(0)
        await first.value
        XCTAssertTrue(vm.isLoading, "the newer load is still running")
        XCTAssertTrue(vm.spaces.isEmpty, "the superseded listing is not applied")

        cli.releaseSpaces(1)
        await second.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.spaces.map(\.key), ["ENG", "OPS"])
    }

    func testOverlappingLoadsOlderFinishingLastIsIgnored() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesQueue = [#"[{"key":"OLD","name":"Stale","id":"1","selected":false}]"#, Self.twoSpaces]
        cli.gatedSpacesCalls = [0, 1]
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)

        let first = Task { await vm.load() }
        guard await waitUntil("first spaces call", { cli.spacesCalls == 1 }) else { return }
        let second = Task { await vm.load() }
        guard await waitUntil("second spaces call", { cli.spacesCalls == 2 }) else { return }

        cli.releaseSpaces(1)
        await second.value
        XCTAssertFalse(vm.isLoading)
        cli.releaseSpaces(0)
        await first.value

        XCTAssertEqual(vm.spaces.map(\.key), ["ENG", "OPS"], "the stale listing never overwrites the newer one")
        XCTAssertFalse(vm.isLoading)
    }

    /// A second toggle of the same space while its CLI call is still running
    /// is a no-op (the busyKeys guard), never a second `select`.
    func testDoubleToggleWhileInFlightRunsOneSelect() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        cli.armSelectGate()
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()

        let first = Task { await vm.setSelected("ENG", true) }
        guard await waitUntil("select call", { cli.selectCount == 1 }) else { return }
        XCTAssertTrue(vm.busyKeys.contains("ENG"))

        await vm.setSelected("ENG", true)
        XCTAssertEqual(cli.selectCount, 1, "the re-entrant toggle ran no CLI call")
        XCTAssertTrue(vm.busyKeys.contains("ENG"), "and did not clear the in-flight marker")

        cli.openSelectGate()
        await first.value
        XCTAssertEqual(cli.selectCount, 1)
        XCTAssertTrue(vm.busyKeys.isEmpty)
        XCTAssertEqual(vm.spaces.first { $0.key == "ENG" }?.selected, true)
    }

    func testReconsentFailureIsMirroredThenClearedOnSuccess() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesError = Self.consentMessage
        var nextResult: String? = "Granting Confluence access failed (exit 1)"
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli) { _ in nextResult }
        await vm.load()

        await vm.reconsentAsync()
        XCTAssertEqual(vm.reconsentError, "Granting Confluence access failed (exit 1)")
        XCTAssertTrue(vm.needsConsent)

        nextResult = nil
        await vm.reconsentAsync()
        XCTAssertNil(vm.reconsentError)
    }

    /// A DB-read error clears on the next good read; a CLI error does not
    /// (only the next CLI call may replace it).
    func testRefreshStatusesClearsOnlyItsOwnError() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()

        try await pool.write { db in try db.execute(sql: "DROP TABLE ext_documents; DROP TABLE ext_sources") }
        await vm.refreshStatuses()
        XCTAssertEqual(vm.errorMessage?.hasPrefix("Failed to read Confluence sync state"), true)

        try await pool.write { db in try db.execute(sql: TestDatabase.schema) }
        await vm.refreshStatuses()
        XCTAssertNil(vm.errorMessage, "a good read clears the stale DB-read error")

        cli.spacesError = "listing Confluence spaces: HTTP 502"
        await vm.load()
        XCTAssertEqual(vm.errorMessage, "listing Confluence spaces: HTTP 502")
        await vm.refreshStatuses()
        XCTAssertEqual(vm.errorMessage, "listing Confluence spaces: HTTP 502", "a CLI error survives a status poll")
    }

    // MARK: - Allow editing (spec 2026-09-30 §2, §6)

    private func loadedVM(
        accessJSON: String,
        spacesError: String? = nil,
        onAllowEditing: @escaping @MainActor (Int64) async -> String? = { _ in nil }
    ) async throws -> (ConfluenceSpacesViewModel, ScriptedConfluenceCLI, Int64) {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        cli.spacesError = spacesError
        cli.accessJSON = accessJSON
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli, onAllowEditing: onAllowEditing)
        await vm.load()
        return (vm, cli, acct)
    }

    /// Read without write: `canEdit` is false and "Allow editing" shows. The
    /// access comes from `confluence access --account N --json`.
    func testReadWithoutWriteShowsAllowEditing() async throws {
        let (vm, cli, acct) = try await loadedVM(accessJSON: #"{"read":true,"write":false}"#)
        XCTAssertTrue(cli.invocations.contains(["confluence", "access", "--account", String(acct), "--json"]))
        XCTAssertTrue(vm.hasReadAccess)
        XCTAssertFalse(vm.canEdit)
        XCTAssertTrue(vm.showsAllowEditing)
        XCTAssertNil(vm.errorMessage)
    }

    func testWriteGrantedHidesAllowEditing() async throws {
        let (vm, _, _) = try await loadedVM(accessJSON: #"{"read":true,"write":true}"#)
        XCTAssertTrue(vm.canEdit)
        XCTAssertFalse(vm.showsAllowEditing)
    }

    /// No read access: the consent flow comes first, never "Allow editing".
    func testNoReadAccessHidesAllowEditing() async throws {
        let (vm, _, _) = try await loadedVM(accessJSON: #"{"read":false,"write":true}"#)
        XCTAssertFalse(vm.showsAllowEditing)
        let (consentVM, _, _) = try await loadedVM(accessJSON: #"{"read":true,"write":false}"#,
                                                   spacesError: Self.consentMessage)
        XCTAssertTrue(consentVM.needsConsent)
        XCTAssertFalse(consentVM.showsAllowEditing, "never over the consent screen")
    }

    /// A failed access check (e.g. a corrupt token) hides the button and says
    /// why — it is never read as "no write access" silently.
    func testAccessFailureIsShownAndHidesAllowEditing() async throws {
        let manager = try makeManager()
        let pool = manager.dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let cli = ScriptedConfluenceCLI(pool: pool)
        cli.spacesJSON = Self.twoSpaces
        cli.accessJSON = #"{"read":true,"write":true}"#
        let vm = ConfluenceSpacesViewModel(accountID: acct, dbPool: pool, runner: cli)
        await vm.load()
        XCTAssertTrue(vm.canEdit)

        cli.accessError = "log line\nreading jira account 1 token: invalid character 'n'"
        await vm.load()

        XCTAssertFalse(vm.canEdit)
        XCTAssertFalse(vm.showsAllowEditing)
        XCTAssertEqual(vm.errorMessage,
                       "Couldn't check Confluence editing access: reading jira account 1 token: invalid character 'n'")
        XCTAssertEqual(vm.spaces.count, 2, "the spaces still list")
    }

    /// "Allow editing" runs the injected write-scope login flow for this
    /// account, then reloads — the re-read access hides the button.
    func testAllowEditingRunsTheWriteLoginThenReloads() async throws {
        var cliRef: ScriptedConfluenceCLI?
        var called: [Int64] = []
        let (vm, cli, acct) = try await loadedVM(accessJSON: #"{"read":true,"write":false}"#) { id in
            called.append(id)
            cliRef?.accessJSON = #"{"read":true,"write":true}"#
            return nil
        }
        cliRef = cli
        XCTAssertTrue(vm.showsAllowEditing)

        await vm.allowEditingAsync()

        XCTAssertEqual(called, [acct])
        XCTAssertTrue(vm.canEdit)
        XCTAssertFalse(vm.showsAllowEditing)
        XCTAssertNil(vm.reconsentError)
        XCTAssertFalse(vm.isReconsenting)
    }

    func testAllowEditingFailureIsMirrored() async throws {
        let (vm, _, _) = try await loadedVM(accessJSON: #"{"read":true,"write":false}"#) { _ in
            "Allowing Confluence editing failed (exit 1)"
        }
        await vm.allowEditingAsync()
        XCTAssertEqual(vm.reconsentError, "Allowing Confluence editing failed (exit 1)")
        XCTAssertTrue(vm.showsAllowEditing, "still not writable")
    }
}
