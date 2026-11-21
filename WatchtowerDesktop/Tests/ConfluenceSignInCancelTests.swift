import DesignKit
import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Answers `confluence spaces` (a consent error when `needsConsent`, else no
/// spaces) and `confluence access` with set texts, and counts the access
/// reads (one per `load()`). No process is spawned.
private final class FixedConfluenceRunner: CLIRunnerProtocol, @unchecked Sendable {
    static let consentError =
        "Confluence access not granted — run: watchtower jira login --account 1 --with-confluence"
    let needsConsent: Bool
    private let lock = NSLock()
    private var access: String
    private var reads = 0

    init(needsConsent: Bool, accessJSON: String = #"{"read":true,"write":false}"#) {
        self.needsConsent = needsConsent
        access = accessJSON
    }

    var accessJSON: String {
        get { lock.withLock { access } }
        set { lock.withLock { access = newValue } }
    }

    /// How many loads ran (`confluence access` calls).
    var loads: Int { lock.withLock { reads } }

    func run(args: [String]) async throws -> Data {
        switch args.dropFirst().first {
        case "spaces":
            if needsConsent { throw CLIRunnerError.nonZeroExit(code: 1, stderr: Self.consentError) }
            return Data("[]".utf8)
        case "access":
            return lock.withLock {
                reads += 1
                return Data(access.utf8)
            }
        default:
            return Data()
        }
    }

    func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
}

/// A login flow the test ends by hand: call N waits until `finish(N, with:)`
/// gives its error (nil = success). Cancels are recorded.
@MainActor
private final class HeldLoginFlow {
    private(set) var cancels: [Int64] = []
    private var calls = 0
    private var waiters: [Int: CheckedContinuation<String?, Never>] = [:]
    private var early: [Int: String?] = [:]

    func run(_: Int64) async -> String? {
        calls += 1
        let call = calls
        if let result = early.removeValue(forKey: call) { return result }
        return await withCheckedContinuation { waiters[call] = $0 }
    }

    func finish(_ call: Int, with error: String?) {
        if let waiter = waiters.removeValue(forKey: call) {
            waiter.resume(returning: error)
        } else {
            early[call] = error
        }
    }

    func cancel(_ id: Int64) { cancels.append(id) }
}

/// Connections → Jira → Confluence, **Grant Confluence access** and
/// **Allow editing** waiting in the browser (#2132 A2): the section shows
/// the waiting line, and its Cancel ends the Jira login flow silently.
@MainActor
final class ConfluenceSignInCancelTests: XCTestCase {
    private let copy = SignInWaitCopy.atlassian
    private let failure = "Granting Confluence access failed (exit 1)"

    private func manager() throws -> DatabaseManager {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return manager
    }

    private func heldVM() async throws -> (ConfluenceSpacesViewModel, HeldLoginFlow, Int64, FixedConfluenceRunner) {
        let pool = try manager().dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let flow = HeldLoginFlow()
        let runner = FixedConfluenceRunner(needsConsent: false)
        let vm = ConfluenceSpacesViewModel(
            accountID: acct, dbPool: pool, runner: runner,
            onReconsent: { await flow.run($0) },
            onAllowEditing: { await flow.run($0) },
            onCancelReconsent: { flow.cancel($0) }
        )
        return (vm, flow, acct, runner)
    }

    /// Grant Confluence access and Allow editing share the trio.
    private enum Start: CaseIterable { case reconsent, allowEditing }

    private func begin(_ start: Start, _ vm: ConfluenceSpacesViewModel) -> Task<Void, Never> {
        switch start {
        case .reconsent: Task { await vm.reconsentAsync() }
        case .allowEditing: Task { await vm.allowEditingAsync() }
        }
    }

    // MARK: - The cancel trio

    /// Start → waiting; Cancel → idle at once, no error, the Jira flow told
    /// to end; the cancelled flow's failure is never shown, and once it ends
    /// the section is re-read once (whatever the CLI saved shows).
    func testCancelIsSilent() async throws {
        for start in Start.allCases {
            let (vm, flow, acct, runner) = try await heldVM()
            let run = begin(start, vm)
            await untilObserved { vm.isWaitingForSignIn }
            XCTAssertTrue(vm.isReconsenting, "\(start)")

            vm.cancelReconsent()
            XCTAssertFalse(vm.isReconsenting, "\(start)")
            XCTAssertFalse(vm.isWaitingForSignIn, "\(start)")
            XCTAssertNil(vm.reconsentError, "\(start)")
            XCTAssertEqual(flow.cancels, [acct], "\(start)")

            flow.finish(1, with: failure)
            await run.value
            XCTAssertNil(vm.reconsentError, "\(start): a Cancel is not an error")
            XCTAssertFalse(vm.isReconsenting, "\(start)")
            XCTAssertEqual(runner.loads, 1, "\(start): one re-read after the Cancel")
        }
    }

    /// The flow already ended: Cancel finds nothing to end and leaves the
    /// section idle with no error.
    func testCancelAfterTheFlowEndedIsSilent() async throws {
        for start in Start.allCases {
            let (vm, flow, _, _) = try await heldVM()
            let run = begin(start, vm)
            flow.finish(1, with: nil)
            await run.value
            vm.cancelReconsent()
            XCTAssertFalse(vm.isReconsenting, "\(start)")
            XCTAssertNil(vm.reconsentError, "\(start)")
            XCTAssertEqual(flow.cancels, [], "\(start): no flow left to end")
        }
    }

    /// Cancel, start again, then the first flow ends with a failure: the new
    /// run is still waiting, and the stale failure is not shown.
    func testStaleEndKeepsTheNewRunWaiting() async throws {
        for start in Start.allCases {
            let (vm, flow, _, runner) = try await heldVM()
            let first = begin(start, vm)
            await untilObserved { vm.isWaitingForSignIn }
            vm.cancelReconsent()

            let second = begin(start, vm)
            await untilObserved { vm.isWaitingForSignIn }
            flow.finish(1, with: failure)
            await first.value
            XCTAssertTrue(vm.isReconsenting, "\(start)")
            XCTAssertTrue(vm.isWaitingForSignIn, "\(start)")
            XCTAssertNil(vm.reconsentError, "\(start)")
            XCTAssertEqual(runner.loads, 0, "\(start): the newer run re-reads at its own end")

            flow.finish(2, with: nil)
            await second.value
            XCTAssertFalse(vm.isReconsenting, "\(start)")
            XCTAssertNil(vm.reconsentError, "\(start)")
        }
    }

    // MARK: - AppState wiring and the section

    /// A Jira account set up with the stub CLI, its Confluence view model
    /// from AppState (`onCancelReconsent` wired as in the app), and a maker
    /// for its section.
    private struct Wired {
        let jira: JiraAccountsViewModel
        let vm: ConfluenceSpacesViewModel
        let runner: FixedConfluenceRunner
        let accounts: [JiraAccount]
        let section: () -> AnyView
    }

    private func wired(needsConsent: Bool, stub: AtlassianSignInStub, sites: Int = 1) async throws -> Wired {
        let manager = try manager()
        try await manager.dbPool.write { db in
            for site in 1...sites {
                _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://acme\(site).atlassian.net")
            }
        }
        let jira = JiraAccountsViewModel(dbPool: manager.dbPool, daemon: FakeDaemonRestarter()) { stub.cli }
        await jira.refreshAsync()
        let account = try XCTUnwrap(jira.accounts.first)
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.jiraAccountsViewModel = jira
        let runner = FixedConfluenceRunner(needsConsent: needsConsent)
        let vm = try XCTUnwrap(appState.confluenceSpacesViewModel(forJiraAccount: Int64(account.id), runner: runner))
        await vm.load()
        let section = { AnyView(ConfluenceSpacesSection(account: account, title: "Confluence").environment(appState)) }
        return Wired(jira: jira, vm: vm, runner: runner, accounts: jira.accounts, section: section)
    }

    /// The section's waiting line over a real `jira login --with-confluence`
    /// (a stub that waits): its Cancel ends the Jira flow, the section is
    /// re-read once the flow ends, and it offers Grant Confluence access
    /// again, with no error.
    func testGrantAccessWaitsAndCancels() async throws {
        try await waitsAndCancels(needsConsent: true, button: "Grant Confluence access",
                                  flag: "--with-confluence") { await $0.reconsentAsync() }
    }

    /// The same for Allow editing (`--with-confluence-write`).
    func testAllowEditingWaitsAndCancels() async throws {
        try await waitsAndCancels(needsConsent: false, button: "Allow editing",
                                  flag: "--with-confluence-write") { await $0.allowEditingAsync() }
    }

    private func waitsAndCancels(
        needsConsent: Bool,
        button: String,
        flag: String,
        start: @escaping @MainActor (ConfluenceSpacesViewModel) async -> Void
    ) async throws {
        let stub = try AtlassianSignInStub(test: self)
        let wired = try await wired(needsConsent: needsConsent, stub: stub)
        let (jira, vm, section) = (wired.jira, wired.vm, wired.section)
        let account = try XCTUnwrap(wired.accounts.first)
        XCTAssertNoThrow(try section().inspect().find(button: button))
        XCTAssertThrowsError(try section().inspect().find(text: copy.line))

        let run = Task { await start(vm) }
        await stub.started(1, of: run)
        XCTAssertTrue(jira.isConnecting)
        XCTAssertNoThrow(try section().inspect().find(text: copy.line))
        XCTAssertNoThrow(try section().inspect().find(text: copy.hint))
        XCTAssertThrowsError(try section().inspect().find(button: button))

        let loadsBefore = wired.runner.loads
        try section().inspect().find(SignInWaitLine.self).find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isReconsenting)
        XCTAssertFalse(jira.isConnecting, "the Cancel ended the Jira login flow")
        await run.value
        XCTAssertEqual(wired.runner.loads, loadsBefore + 1, "one re-read after the Cancel")
        XCTAssertNil(vm.reconsentError)
        XCTAssertNil(jira.error)
        XCTAssertNoThrow(try section().inspect().find(button: button))
        XCTAssertEqual(stub.argv, ["jira login --account \(account.id) --app-return \(flag)"])
    }

    /// A reload while Allow editing waits drops the read access, so the
    /// editing branch goes: the waiting line and its Cancel stay.
    func testWaitingLineOutlivesAReloadThatHidesAllowEditing() async throws {
        let stub = try AtlassianSignInStub(test: self)
        let wired = try await wired(needsConsent: false, stub: stub)
        let (vm, section) = (wired.vm, wired.section)
        let run = Task { await vm.allowEditingAsync() }
        await stub.started(1, of: run)

        wired.runner.accessJSON = #"{"read":false,"write":false}"#
        await vm.load()
        XCTAssertFalse(vm.showsAllowEditing)
        XCTAssertNoThrow(try section().inspect().find(text: copy.line))
        try section().inspect().find(SignInWaitLine.self).find(button: copy.cancelTitle).tap()
        XCTAssertFalse(wired.jira.isConnecting)
        await run.value
        XCTAssertThrowsError(try section().inspect().find(text: copy.line))
    }

    /// The grant's flow is ended elsewhere (the Jira Cancel), and a Re-login
    /// of another site starts: the Confluence section's stale Cancel leaves
    /// that Re-login running.
    func testStaleConfluenceCancelLeavesAnotherSignInRunning() async throws {
        let stub = try AtlassianSignInStub(ignoresTerm: true, test: self)
        let wired = try await wired(needsConsent: true, stub: stub, sites: 2)
        let (jira, vm) = (wired.jira, wired.vm)
        let other = try XCTUnwrap(wired.accounts.first { Int64($0.id) != vm.accountID })
        let grant = Task { await vm.reconsentAsync() }
        await stub.started(1, of: grant)
        jira.cancelConnect()

        let relogin = Task { await jira.relogin(other) }
        await stub.started(2, of: relogin)
        XCTAssertTrue(vm.isWaitingForSignIn, "the grant's flow has not ended yet")
        vm.cancelReconsent()
        XCTAssertTrue(jira.isConnecting, "the other site's Re-login still runs")
        XCTAssertEqual(jira.signInAccountID, other.id)

        await stub.release(1, exitCode: 1)
        await grant.value
        jira.cancelConnect()
        await stub.release(2, exitCode: 1)
        await relogin.value
        XCTAssertNil(vm.reconsentError)
        XCTAssertNil(jira.error)
    }
}
