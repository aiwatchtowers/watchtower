import DesignKit
import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Answers `confluence spaces` (a consent error when `needsConsent`, else no
/// spaces) and `confluence access` with fixed texts. No process is spawned.
private final class FixedConfluenceRunner: CLIRunnerProtocol, @unchecked Sendable {
    static let consentError =
        "Confluence access not granted — run: watchtower jira login --account 1 --with-confluence"
    let needsConsent: Bool
    let accessJSON: String

    init(needsConsent: Bool, accessJSON: String = #"{"read":true,"write":false}"#) {
        self.needsConsent = needsConsent
        self.accessJSON = accessJSON
    }

    func run(args: [String]) async throws -> Data {
        switch args.dropFirst().first {
        case "spaces":
            if needsConsent { throw CLIRunnerError.nonZeroExit(code: 1, stderr: Self.consentError) }
            return Data("[]".utf8)
        case "access":
            return Data(accessJSON.utf8)
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

    private func heldVM() async throws -> (ConfluenceSpacesViewModel, HeldLoginFlow, Int64) {
        let pool = try manager().dbPool
        let acct = try await pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let flow = HeldLoginFlow()
        let vm = ConfluenceSpacesViewModel(
            accountID: acct, dbPool: pool, runner: FixedConfluenceRunner(needsConsent: false),
            onReconsent: { await flow.run($0) },
            onAllowEditing: { await flow.run($0) },
            onCancelReconsent: { flow.cancel($0) }
        )
        return (vm, flow, acct)
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
    /// to end; the cancelled flow's failure is never shown.
    func testCancelIsSilent() async throws {
        for start in Start.allCases {
            let (vm, flow, acct) = try await heldVM()
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
        }
    }

    /// The flow already ended: Cancel finds nothing to end and leaves the
    /// section idle with no error.
    func testCancelAfterTheFlowEndedIsSilent() async throws {
        for start in Start.allCases {
            let (vm, flow, _) = try await heldVM()
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
            let (vm, flow, _) = try await heldVM()
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

            flow.finish(2, with: nil)
            await second.value
            XCTAssertFalse(vm.isReconsenting, "\(start)")
            XCTAssertNil(vm.reconsentError, "\(start)")
        }
    }

    // MARK: - AppState wiring and the section

    /// The section's waiting line over a real `jira login --with-confluence`
    /// (a stub that waits): its Cancel ends the Jira flow, and the section
    /// offers Grant Confluence access again, with no error.
    func testGrantAccessWaitsAndCancels() async throws {
        try await waitsAndCancels(needsConsent: true, button: "Grant Confluence access",
                                  flag: "--with-confluence") { $0.reconsent() }
    }

    /// The same for Allow editing (`--with-confluence-write`).
    func testAllowEditingWaitsAndCancels() async throws {
        try await waitsAndCancels(needsConsent: false, button: "Allow editing",
                                  flag: "--with-confluence-write") { $0.allowEditing() }
    }

    private func waitsAndCancels(
        needsConsent: Bool, button: String, flag: String, start: (ConfluenceSpacesViewModel) -> Void
    ) async throws {
        let manager = try manager()
        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net")
        }
        let stub = try AtlassianSignInStub(test: self)
        let jira = JiraAccountsViewModel(dbPool: manager.dbPool, daemon: FakeDaemonRestarter()) { stub.cli }
        await jira.refreshAsync()
        let account = try XCTUnwrap(jira.accounts.first)
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.jiraAccountsViewModel = jira
        let vm = try XCTUnwrap(appState.confluenceSpacesViewModel(
            forJiraAccount: Int64(account.id), runner: FixedConfluenceRunner(needsConsent: needsConsent)))
        await vm.load()
        let section = { ConfluenceSpacesSection(account: account, title: "Confluence").environment(appState) }
        XCTAssertNoThrow(try section().inspect().find(button: button))
        XCTAssertThrowsError(try section().inspect().find(text: copy.line))

        start(vm)
        await stub.started(1)
        XCTAssertTrue(jira.isConnecting)
        XCTAssertNoThrow(try section().inspect().find(text: copy.line))
        XCTAssertNoThrow(try section().inspect().find(text: copy.hint))
        XCTAssertThrowsError(try section().inspect().find(button: button))

        try section().inspect().find(SignInWaitLine.self).find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isReconsenting)
        XCTAssertFalse(jira.isConnecting, "the Cancel ended the Jira login flow")
        XCTAssertNil(vm.reconsentError)
        XCTAssertNoThrow(try section().inspect().find(button: button))
        XCTAssertEqual(stub.argv, ["jira login --account \(account.id) --app-return \(flag)"])
    }
}
