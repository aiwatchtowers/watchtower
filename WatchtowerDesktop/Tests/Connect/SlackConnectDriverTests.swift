import Foundation
import GRDB
import Observation
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// The accounts view model's stand-in. Like the real one, a sign-in's rows
/// land only on the next `refreshAsync` (its own reload is fire-and-forget).
/// `slack add` is held until the test finishes it; `beginForeignSignIn`
/// stands for a run the Connections UI started (Reconnect, Re-login).
@MainActor
@Observable
private final class FakeSlackAccounts: SlackAccountsConnecting {
    var accounts: [SlackAccount] = []
    var isConnecting = false
    private(set) var isSigningIn = false
    private(set) var authRunSerial = 0
    private(set) var lastAuthRun: SlackAuthRun?
    var error: String?
    var builtinApp = true
    private(set) var addCalls = 0
    private(set) var cancelCalls = 0
    /// What the next `refreshAsync` reads from the database.
    @ObservationIgnored var stored: [SlackAccount]?
    @ObservationIgnored private var addWaiter: CheckedContinuation<Void, Never>?

    func addAccount(daemonPolicy _: DaemonRestartPolicy) async {
        addCalls += 1
        beginForeignSignIn()
        await withCheckedContinuation { addWaiter = $0 }
    }

    /// A sign-in run begins (as `runAuthFlow` does).
    func beginForeignSignIn() {
        isConnecting = true
        isSigningIn = true
        authRunSerial += 1
    }

    /// Run `serial` (default: the newest) ended as `end`; `rows` is what the
    /// database holds now. Recorded as the real VM does (`recorded`).
    func finishSignIn(_ end: SlackAuthRunEnd, rows: [SlackAccount]? = nil, serial: Int? = nil) {
        let serial = serial ?? authRunSerial
        if let rows { stored = rows }
        if case let .failed(message) = end { error = message } else { error = nil }
        if serial == authRunSerial {
            isConnecting = false
            isSigningIn = false
        }
        lastAuthRun = SlackAccountsViewModel.recorded(lastAuthRun, SlackAuthRun(serial: serial, end: end))
        addWaiter?.resume()
        addWaiter = nil
    }

    func cancelConnect() {
        cancelCalls += 1
        finishSignIn(.cancelled)
    }

    /// While set, `refreshAsync` waits until `releaseRefresh`.
    @ObservationIgnored var holdRefresh = false
    @ObservationIgnored private var refreshWaiter: CheckedContinuation<Void, Never>?
    private(set) var refreshHeld = false

    func releaseRefresh() {
        holdRefresh = false
        refreshWaiter?.resume()
        refreshWaiter = nil
    }

    func refreshAsync() async {
        if holdRefresh {
            refreshHeld = true
            await withCheckedContinuation { refreshWaiter = $0 }
            refreshHeld = false
        }
        if let stored { accounts = stored }
    }
}

/// `SlackConnectDriver` on the real connect flow (a fake `slack connect
/// serve` child), the real setup model (a scripted `slack app` CLI) and a
/// fake accounts view model.
@MainActor
final class SlackConnectDriverTests: XCTestCase {
    private let code = "T0ACME:1111.2222"
    private let token = "xoxe-1-acme-config-token"  // leak-check:allow (a fake)
    private let noSetups = FakeCLILineStream.Reply(lines: [#"{"setups":[]}"#])

    @MainActor
    private struct Rig {
        let driver: SlackConnectDriver
        let flow: SlackConnectFlowModel
        let child: FakeCLILineSession
        let host: SlackConnectListenerHost
        let setup: SlackAppSetupModel
        let setupCLI: FakeCLILineStream
        let accounts: FakeSlackAccounts
        let runner: FakeCLIRunner

        func emit(_ event: SlackConnectEvent) { host.onEvent?(event) }
    }

    private func makeRig(
        replies: [FakeCLILineStream.Reply] = [],
        policy: ManagedPolicy = ManagedPolicy(),
        runner: FakeCLIRunner = FakeCLIRunner()
    ) async -> Rig {
        let listenerCLI = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: listenerCLI)
        let flow = SlackConnectFlowModel(host: host)
        host.ensureRunning()
        let child = await listenerCLI.session(number: 1)
        child.emit(#"{"event":"listening","port":18551}"#)
        await untilObserved { host.state == .listening }
        // Strict: an unscripted `slack app` call fails the test instead of hanging it.
        let setupCLI = FakeCLILineStream(replies: replies, strict: true)
        setupCLI.onUnscripted = { args in XCTFail("unscripted CLI call: \(args)") }
        let setup = SlackAppSetupModel(streamer: setupCLI)
        let accounts = FakeSlackAccounts()
        var next = 0
        let flowIDs: () -> String = {
            next += 1
            return "flow-\(next)"
        }
        let driver = SlackConnectDriver(
            accounts: accounts, connectFlow: flow, setup: setup, policy: { policy }, runner: runner, makeFlowID: flowIDs)
        return Rig(driver: driver, flow: flow, child: child, host: host, setup: setup, setupCLI: setupCLI,
                   accounts: accounts, runner: runner)
    }

    private func result(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func success<T>(_ result: Result<T, ConnectDriverError>, file: StaticString = #filePath, line: UInt = #line) -> T? {
        switch result {
        case let .success(value): return value
        case let .failure(error):
            XCTFail("expected success, got \(error)", file: file, line: line)
            return nil
        }
    }

    private func account(
        id: Int, team: String, name: String, label: String = "", client: String = "1111.2222", status: String = "ok"
    ) -> SlackAccount {
        SlackAccount(row: Row(["id": id, "team_id": team, "team_name": name, "label": label, "status": status, "client_id": client]))
    }

    // MARK: - Busy and policy

    func testSlackDriverBusyWhenFlowModelRunning() async {
        let rig = await makeRig()
        rig.flow.pasteText = code
        XCTAssertTrue(rig.flow.connectPasted(), "a paste in Connections → Slack runs the flow")

        let byCode = await rig.driver.start(options: ["code": code])
        XCTAssertEqual(byCode, .failure(.busy))
        let byButton = await rig.driver.start(options: [:])
        XCTAssertEqual(byButton, .failure(.busy))
        let update = await rig.driver.start(options: ["pkce": "1"])
        XCTAssertEqual(update, .failure(.busy))
        XCTAssertEqual(rig.accounts.addCalls, 0)
        rig.setupCLI.enqueue(noSetups)  // `slack app status` answers; an unscripted run would never end
        let status = await rig.driver.status()
        XCTAssertEqual(status.flow, ConnectStatus.Flow(id: "flow-1", state: "starting"),
                       "the paste's flow shows under its own id, so the agent can wait for it or cancel it")
    }

    func testSecondStartIsBusyWhileOurFlowRuns() async {
        let rig = await makeRig()
        let first = await rig.driver.start(options: ["code": code])
        XCTAssertEqual(first, .success("flow-1"))
        let second = await rig.driver.start(options: ["code": code])
        XCTAssertEqual(second, .failure(.busy))
    }

    func testPolicyBlockedSlack() async throws {
        var blocked = ManagedPolicy()
        blocked.managed = true
        blocked.allowedSources = ["google"]
        let rig = await makeRig(policy: blocked)

        XCTAssertFalse(rig.driver.policyAllows())
        let start = await rig.driver.start(options: ["code": code])
        XCTAssertEqual(start, .failure(.policy))
        let secret = await rig.driver.submitSecret(kind: SlackConnectDriver.configTokenKind, value: token)
        if case .failure(.policy) = secret {} else { XCTFail("the token is refused under the policy: \(secret)") }
        rig.setupCLI.enqueue(noSetups)
        let status = await rig.driver.status()
        XCTAssertTrue(status.policyLocked)
        XCTAssertEqual(rig.child.writtenLines, [], "nothing reached the connect listener")
        XCTAssertFalse(rig.setupCLI.invocations.contains { $0.args.contains("create") || $0.args.contains("adopt") })
    }

    func testOrganizationSlackAppsRowIsTheNoOptionStart() async {
        var policy = ManagedPolicy()
        policy.managed = true
        policy.slackApps = [ManagedPolicy.SlackApp(teamID: "T0ACME", clientID: "9999.8888")]
        let rig = await makeRig(policy: policy)

        XCTAssertTrue(rig.driver.policyAllows(), "SlackApps provisions apps; it does not block Slack")
        let orgRow = await rig.driver.start(options: [:])
        XCTAssertEqual(orgRow, .success("flow-1"), "no option: the organization's app, as its row in the connect section")
        await untilObserved { rig.flow.isRunning }
        XCTAssertEqual(rig.child.writtenLines, [#"{"client_id":"9999.8888","cmd":"start","team_id":"T0ACME"}"#])
        XCTAssertEqual(rig.accounts.addCalls, 0)
    }

    // MARK: - The personal sign-in

    func testCodeStartConnectsAndWaitReturnsTheWorkspace() async {
        let rig = await makeRig()
        let flowID = success(await rig.driver.start(options: ["code": " http://127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222 "]))
        XCTAssertEqual(flowID, "flow-1")
        XCTAssertEqual(rig.child.writtenLines, [#"{"client_id":"1111.2222","cmd":"start","team_id":"T0ACME"}"#],
                       "the panel's Start is the press: no confirm step (SLACKFULL-01, ask #1721)")
        rig.emit(.browser(flow: "f1"))
        await untilObserved { if case .browser = rig.flow.step { true } else { false } }
        rig.setupCLI.enqueue(noSetups)
        let running = await rig.driver.status()
        XCTAssertEqual(running.flow, ConnectStatus.Flow(id: "flow-1", state: "browser"))

        async let outcome = rig.driver.wait(flowID: "flow-1")
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 3, teamID: "T0ACME", teamName: "Acme", reboundFrom: "")))
        let waited = await outcome
        XCTAssertEqual(waited, .connected(account: "Acme"))
        let again = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(again, .connected(account: "Acme"), "an ended flow answers at once")
        rig.setupCLI.enqueue(noSetups)
        let after = await rig.driver.status()
        XCTAssertNil(after.flow)
    }

    func testBadCodeIsRefusedBeforeAnythingStarts() async {
        let rig = await makeRig()
        let start = await rig.driver.start(options: ["code": "not a code"])
        XCTAssertEqual(start, .failure(.badArgs(SlackConnectFlowModel.pasteInvalid)))
        let unknown = await rig.driver.start(options: ["scopes": "x"])
        if case .failure(.badArgs) = unknown {} else { XCTFail("an unknown option is refused: \(unknown)") }
        XCTAssertEqual(rig.child.writtenLines, [])
    }

    /// A sign-in the assistant starts shows in its panel, not as the flow
    /// sheet over it: neither host (the onboarding Connect step, the Slack
    /// detail) presents one, and its end leaves the flow idle (no sheet
    /// waits for Done). A manual start and an incoming link keep the sheet.
    func testAssistantFlowShowsNoSheetInEitherHost() async {
        let rig = await makeRig()
        let hostsShowSheet: () -> (onboarding: Bool, detail: Bool) = {
            (OnboardingConnectStepView.sheet(nil, flowShowsSheet: rig.flow.showsSheet) != nil,
             SlackConnectionDetail.showsConnectSheet(flow: rig.flow, setupPresented: false))
        }
        _ = await rig.driver.start(options: ["code": code])
        XCTAssertTrue(rig.flow.isRunning)
        XCTAssertTrue(rig.flow.startedByAssistant)
        XCTAssertFalse(hostsShowSheet().onboarding)
        XCTAssertFalse(hostsShowSheet().detail)
        rig.emit(.browser(flow: "f1"))
        await untilObserved { if case .browser = rig.flow.step { true } else { false } }
        XCTAssertFalse(hostsShowSheet().onboarding, "the browser step stays the panel's")
        XCTAssertFalse(hostsShowSheet().detail)
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 3, teamID: "T0ACME", teamName: "Acme", reboundFrom: "")))
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .connected(account: "Acme"))
        await untilObserved { rig.flow.step == .idle }
        XCTAssertFalse(rig.flow.startedByAssistant)

        // A manual start (the connect section's paste) keeps today's sheet.
        rig.flow.pasteText = code
        XCTAssertTrue(rig.flow.connectPasted())
        XCTAssertFalse(rig.flow.startedByAssistant)
        XCTAssertTrue(hostsShowSheet().onboarding)
        XCTAssertTrue(hostsShowSheet().detail)
    }

    func testCancelEndsOnlyTheNamedFlow() async {
        let rig = await makeRig()
        _ = await rig.driver.start(options: ["code": code])
        rig.emit(.browser(flow: "f1"))
        await untilObserved { if case .browser = rig.flow.step { true } else { false } }

        await rig.driver.cancel(flowID: "flow-9")
        XCTAssertTrue(rig.flow.isRunning, "an unknown id cancels nothing")
        await rig.driver.cancel(flowID: "flow-1")
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .failed(reason: SlackConnectDriver.cancelled))
        XCTAssertEqual(rig.child.writtenLines.last, #"{"cmd":"cancel","flow":"f1"}"#)

        await rig.driver.cancel(flowID: "flow-1")
        XCTAssertEqual(rig.child.writtenLines.count, 2, "an ended flow's id is a no-op")
        let unknown = await rig.driver.wait(flowID: "flow-7")
        XCTAssertEqual(unknown, .failed(reason: SlackConnectDriver.unknownFlow))
    }

    func testWaitCancellationEndsTheWaitNotTheFlow() async {
        let rig = await makeRig()
        _ = await rig.driver.start(options: ["code": code])
        let wait = Task { await rig.driver.wait(flowID: "flow-1") }
        wait.cancel()
        let outcome = await wait.value
        XCTAssertEqual(outcome, .waiting)
        XCTAssertTrue(rig.flow.isRunning)
        XCTAssertEqual(rig.child.writtenLines.count, 1, "no cancel reached the listener")
    }

    func testBuiltinAppStartRunsAddWorkspace() async {
        let rig = await makeRig()
        let flowID = success(await rig.driver.start(options: [:]))
        XCTAssertEqual(flowID, "flow-1")
        await untilObserved { rig.accounts.isConnecting }
        XCTAssertEqual(rig.accounts.addCalls, 1)
        async let outcome = rig.driver.wait(flowID: "flow-1")
        rig.accounts.finishSignIn(.succeeded(accountID: nil), rows: [account(id: 2, team: "T0ACME", name: "Acme")])
        let waited = await outcome
        XCTAssertEqual(waited, .connected(account: "Acme"))
        XCTAssertEqual(rig.child.writtenLines, [])
    }

    func testCancelledAddWorkspaceIsNeverConnected() async {
        let rig = await makeRig()
        _ = await rig.driver.start(options: [:])
        await untilObserved { rig.accounts.isConnecting }
        // Cancelled in the Connections UI, not through connect_cancel: `error` stays nil.
        rig.accounts.finishSignIn(.cancelled)
        let cancelled = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(cancelled, .failed(reason: SlackConnectDriver.cancelled))

        _ = await rig.driver.start(options: [:])
        await untilObserved { rig.accounts.isConnecting }
        rig.accounts.finishSignIn(.succeeded(accountID: nil))
        let nothingWritten = await rig.driver.wait(flowID: "flow-2")
        XCTAssertEqual(nothingWritten, .failed(reason: SlackConnectDriver.signInEnded),
                       "no new or re-bound account: never a made-up name")
    }

    func testForeignReloginWithAnUnchangedRowConnects() async {
        let rig = await makeRig()
        let acme = account(id: 1, team: "T0ACME", name: "Acme")
        let other = account(id: 2, team: "T0OTHER", name: "Other")
        rig.accounts.accounts = [acme, other]
        rig.accounts.beginForeignSignIn()  // Re-login of account 1 from a banner
        rig.setupCLI.enqueue(noSetups)
        let id = await rig.driver.status().flow?.id
        XCTAssertEqual(id, "flow-1")
        // Only the token changed; an unrelated row's label changed meanwhile.
        rig.accounts.finishSignIn(.succeeded(accountID: 1), rows: [acme, account(id: 2, team: "T0OTHER", name: "Other", label: "Renamed")])
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .connected(account: "Acme"), "the re-bound account, never the renamed one")
    }

    func testForeignAddConnectsAfterTheRefresh() async {
        let rig = await makeRig()
        let other = account(id: 2, team: "T0OTHER", name: "Other")
        rig.accounts.accounts = [other]
        rig.accounts.beginForeignSignIn()  // Add workspace in Connections → Slack
        rig.setupCLI.enqueue(noSetups)
        _ = await rig.driver.status()
        rig.accounts.finishSignIn(.succeeded(accountID: nil), rows: [other, account(id: 5, team: "T0ACME", name: "Acme")])
        let added = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(added, .connected(account: "Acme"), "read after the refresh, not off the stale rows")

        rig.accounts.beginForeignSignIn()
        rig.setupCLI.enqueue(noSetups)
        _ = await rig.driver.status()
        rig.accounts.finishSignIn(.succeeded(accountID: nil), rows: [account(id: 2, team: "T0OTHER", name: "Other", label: "Renamed")])
        let nothing = await rig.driver.wait(flowID: "flow-2")
        XCTAssertEqual(nothing, .failed(reason: SlackConnectDriver.signInEnded), "a changed label is no new account")
    }

    func testEachSignInRunGetsItsOwnID() async {
        let rig = await makeRig()
        rig.accounts.beginForeignSignIn()
        rig.setupCLI.enqueue(noSetups)
        let first = await rig.driver.status().flow?.id
        // It ends and a new run starts before the watcher wakes.
        rig.accounts.finishSignIn(.cancelled)
        rig.accounts.beginForeignSignIn()
        rig.setupCLI.enqueue(noSetups)
        let second = await rig.driver.status().flow?.id
        XCTAssertEqual(first, "flow-1")
        XCTAssertEqual(second, "flow-2", "a new run is a new attempt")
        let firstEnd = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(firstEnd, .failed(reason: SlackConnectDriver.cancelled))
        await rig.driver.cancel(flowID: "flow-1")
        XCTAssertTrue(rig.accounts.isSigningIn, "the old id cancels nothing")
        XCTAssertEqual(rig.accounts.cancelCalls, 0)
    }

    func testRouteReadIsNoSignIn() async {
        let rig = await makeRig()
        rig.accounts.isConnecting = true  // Re-login's route read, or enable/disable/remove
        rig.setupCLI.enqueue(noSetups)
        let status = await rig.driver.status()
        XCTAssertNil(status.flow)
        let start = await rig.driver.start(options: [:])
        XCTAssertEqual(start, .failure(.busy))
    }

    func testAddCancelNeverReachesANewerSignIn() async {
        let rig = await makeRig()
        _ = await rig.driver.start(options: [:])
        await untilObserved { rig.accounts.isSigningIn }
        rig.accounts.holdRefresh = true
        rig.accounts.finishSignIn(.succeeded(accountID: nil))
        await untilObserved { rig.accounts.refreshHeld }  // the driver is reading the outcome
        rig.accounts.beginForeignSignIn()  // the sheet starts another sign-in meanwhile
        await rig.driver.cancel(flowID: "flow-1")
        XCTAssertEqual(rig.accounts.cancelCalls, 0, "the newer sign-in is not ours to cancel")
        rig.accounts.releaseRefresh()
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .failed(reason: SlackConnectDriver.signInEnded))
    }

    func testOlderRunEndingLateKeepsTheNewerEnd() async {
        let rig = await makeRig()
        rig.accounts.beginForeignSignIn()
        rig.setupCLI.enqueue(noSetups)
        _ = await rig.driver.status()  // flow-1: run 1
        rig.accounts.beginForeignSignIn()
        rig.setupCLI.enqueue(noSetups)
        _ = await rig.driver.status()  // flow-2: run 2
        rig.accounts.finishSignIn(.succeeded(accountID: nil), rows: [account(id: 4, team: "T0ACME", name: "Acme")])
        rig.accounts.finishSignIn(.cancelled, serial: 1)  // run 1's child exits late
        XCTAssertEqual(rig.accounts.lastAuthRun?.serial, 2)
        let newer = await rig.driver.wait(flowID: "flow-2")
        XCTAssertEqual(newer, .connected(account: "Acme"))
        let older = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(older, .failed(reason: SlackConnectDriver.signInEnded), "its own end is lost, never another run's")
    }

    func testAddNamesThePrintedAccountOverASeededLegacyRow() async {
        let rig = await makeRig()
        _ = await rig.driver.start(options: [:])
        await untilObserved { rig.accounts.isSigningIn }
        // `slack add` seeded legacy account #1, then wrote #2 and printed it.
        let rows = [account(id: 1, team: "T0OLD", name: "Legacy"), account(id: 2, team: "T0ACME", name: "Acme")]
        rig.accounts.finishSignIn(.succeeded(accountID: 2), rows: rows)
        let printed = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(printed, .connected(account: "Acme"))

        _ = await rig.driver.start(options: [:])
        await untilObserved { rig.accounts.isSigningIn }
        rig.accounts.finishSignIn(.succeeded(accountID: nil), rows: rows + [
            account(id: 3, team: "T0OLDER", name: "Seeded"), account(id: 7, team: "T0NEW", name: "Newest")
        ])
        let unprinted = await rig.driver.wait(flowID: "flow-2")
        XCTAssertEqual(unprinted, .connected(account: "Newest"), "no id printed: the highest new id")
    }

    func testReloginNamesItsAccountOverAConcurrentNewRow() async {
        let rig = await makeRig()
        let acme = account(id: 1, team: "T0ACME", name: "Acme")
        rig.accounts.accounts = [acme]
        rig.accounts.beginForeignSignIn()
        rig.setupCLI.enqueue(noSetups)
        _ = await rig.driver.status()
        rig.accounts.finishSignIn(.succeeded(accountID: 1), rows: [acme, account(id: 3, team: "T0NEW", name: "New")])
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .connected(account: "Acme"))
    }

    func testAuthRunRecordingAndPrintedAccount() {
        let newer = SlackAuthRun(serial: 2, end: .succeeded(accountID: nil))
        let older = SlackAuthRun(serial: 1, end: .cancelled)
        XCTAssertEqual(SlackAccountsViewModel.recorded(newer, older), newer)
        XCTAssertEqual(SlackAccountsViewModel.recorded(older, newer), newer)
        XCTAssertEqual(SlackAccountsViewModel.recorded(nil, older), older)
        let out = "\nConnected Slack workspace \"Acme\" (team: T0ACME, user: acme-user)\nAccount id: 12\nRun 'watchtower sync'\n"
        XCTAssertEqual(SlackAccountsViewModel.printedAccountID(out), 12)
        XCTAssertNil(SlackAccountsViewModel.printedAccountID("Connected"))
    }

    func testAuthRunEndFromTheExitStatus() {
        XCTAssertEqual(SlackAccountsViewModel.authEnd(exitCode: 0, error: nil, accountID: 4), .succeeded(accountID: 4))
        XCTAssertEqual(SlackAccountsViewModel.authEnd(exitCode: 0, error: nil, accountID: nil), .succeeded(accountID: nil))
        XCTAssertEqual(SlackAccountsViewModel.authEnd(exitCode: 15, error: nil, accountID: 4), .cancelled)
        XCTAssertEqual(SlackAccountsViewModel.authEnd(exitCode: 9, error: nil, accountID: nil), .cancelled)
        XCTAssertEqual(SlackAccountsViewModel.authEnd(exitCode: 1, error: "denied", accountID: nil), .failed("denied"))
    }

    func testCancelBeforeTheChildAnswersEndsTheFlow() async {
        let rig = await makeRig()
        _ = await rig.driver.start(options: ["code": code])
        await rig.driver.cancel(flowID: "flow-1")
        XCTAssertTrue(rig.flow.isRunning, "the start is still unanswered")
        async let outcome = rig.driver.wait(flowID: "flow-1")
        rig.emit(.browser(flow: "f1"))  // the child answers: the model cancels f1
        let waited = await outcome
        XCTAssertEqual(waited, .failed(reason: SlackConnectDriver.cancelled))
        XCTAssertEqual(rig.child.writtenLines.last, #"{"cmd":"cancel","flow":"f1"}"#)
        let next = await rig.driver.start(options: ["code": code])
        XCTAssertEqual(next, .success("flow-2"), "a later start is no longer busy")
    }

    func testEachForeignSignInHasItsOwnID() async {
        let rig = await makeRig()
        rig.flow.pasteText = code
        rig.flow.connectPasted()
        rig.setupCLI.enqueue(noSetups)
        let first = await rig.driver.status().flow?.id
        XCTAssertEqual(first, "flow-1")
        rig.emit(.browser(flow: "f1"))
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 3, teamID: "T0ACME", teamName: "Acme", reboundFrom: "")))
        let ended = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(ended, .connected(account: "Acme"))
        let again = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(again, .connected(account: "Acme"), "an ended foreign flow keeps its final outcome")

        rig.flow.dismiss()
        rig.flow.pasteText = code
        rig.flow.connectPasted()
        rig.setupCLI.enqueue(noSetups)
        let second = await rig.driver.status().flow?.id
        XCTAssertEqual(second, "flow-2", "a new attempt gets a new id")
        await rig.driver.cancel(flowID: "flow-1")
        XCTAssertTrue(rig.flow.isRunning, "the old id cancels nothing")
    }

    func testNoBuiltinAppNeedsTheCode() async {
        let rig = await makeRig()
        rig.accounts.builtinApp = false
        let start = await rig.driver.start(options: [:])
        if case .failure(.badArgs) = start {} else { XCTFail("no app to sign in with: \(start)") }
        XCTAssertEqual(rig.accounts.addCalls, 0)
    }

    // MARK: - The configuration token

    func testPKCERequiresConfirm() {
        let driver = SlackConnectDriver(
            accounts: FakeSlackAccounts(), connectFlow: nil, setup: SlackAppSetupModel(streamer: nil),
            policy: { ManagedPolicy() }, runner: nil)
        XCTAssertEqual(driver.confirmNeeded(tool: "connect_start", options: ["pkce": "1"]), .slackPKCE)
        XCTAssertEqual(driver.confirmNeeded(tool: "connect_start", options: ["pkce": "true"]), .slackPKCE)
        XCTAssertNil(driver.confirmNeeded(tool: "connect_start", options: ["pkce": "false"]))
        XCTAssertNil(driver.confirmNeeded(tool: "connect_start", options: ["code": code]),
                     "the panel's Start is the press for a personal connect (ask #1721)")
        XCTAssertNil(driver.confirmNeeded(tool: "connect_start", options: [:]))
        XCTAssertEqual(driver.secretKinds, ["slack_config_token"])
    }

    func testConfigTokenGoesOnStdinOnly() async throws {
        let created = #"{"result":"ok","team_id":"T0ACME","team_name":"Acme","app_id":"A0APP","client_id":"1111.2222","link_written":true}"#
        let rig = await makeRig(replies: [FakeCLILineStream.Reply(lines: [created]), noSetups])

        let sent = await rig.driver.submitSecret(kind: SlackConnectDriver.configTokenKind, value: " \(token)\n")
        let data = try XCTUnwrap(success(sent))

        let create = try XCTUnwrap(rig.setupCLI.invocations.first)
        XCTAssertEqual(create.args, ["slack", "app", "create", "--json"])
        XCTAssertEqual(create.stdin, Data("\(token)\n".utf8), "the token is stdin's first line")
        for call in rig.setupCLI.invocations {
            XCTAssertFalse(call.args.joined(separator: " ").contains(token), "never on argv: \(call.args)")
        }
        XCTAssertFalse((String(bytes: data, encoding: .utf8) ?? "").contains(token), "never in the result")
        XCTAssertFalse(rig.setup.holdsToken)
        let json = try result(data)
        // No connector here: the admin's own connect does not run, so the app exists unconnected.
        XCTAssertEqual(json["result"] as? String, "not_connected")
        XCTAssertEqual(json["app_id"] as? String, "A0APP")
        XCTAssertEqual(json["connected"] as? Bool, false)
    }

    func testCreateResultsTellTheOutcomesApart() async throws {
        let cases: [(String, String)] = [
            (#"{"result":"existing_app","team_id":"T0ACME","team_name":"Acme"}"#, "existing_app"),
            (#"{"result":"not_allowed","team_id":"T0ACME","team_name":"Acme"}"#, "not_allowed"),
            (#"{"result":"pending_create","team_id":"T0ACME","team_name":"Acme"}"#, "pending_create")
        ]
        for (line, expected) in cases {
            let rig = await makeRig(replies: [FakeCLILineStream.Reply(lines: [line]), noSetups])
            let sent = await rig.driver.submitSecret(kind: "slack_config_token", value: token)
            let data = try XCTUnwrap(success(sent))
            let json = try result(data)
            XCTAssertEqual(json["result"] as? String, expected, line)
            XCTAssertFalse((json["message"] as? String ?? "").isEmpty, line)
        }
    }

    func testSetupResultOutcomes() throws {
        let model = SlackAppSetupModel(streamer: nil)
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "Acme", appID: "A0APP", clientID: "1111.2222")
        var linked = target
        linked.linkWritten = true
        let outcomes: [(SlackAppSetupModel.Outcome, String, Bool?)] = [ // swiftlint:disable:this discouraged_optional_boolean
            (.success(linked), "ok", true),
            (.linkFailed(target), "link_failed", true),
            (.approval(target), "approval", false),
            (.notConnected(target), "not_connected", false),
            (.problem(.badToken), "bad_token", nil)
        ]
        for (outcome, code, connected) in outcomes {
            let value = SlackConfigTokenResult(phase: .finished(outcome), form: .create, model: model)
            XCTAssertEqual(value.result, code)
            XCTAssertEqual(value.connected, connected, code)
            XCTAssertFalse(value.message.isEmpty, code)
        }
    }

    func testPKCEUpdateRunsAdoptAndOpensNoSignIn() async throws {
        let adopted = #"{"result":"ok","team_id":"T0ACME","team_name":"Acme","app_id":"A0APP","client_id":"1111.2222","link_written":true}"#
        let rig = await makeRig()

        let flowID = success(await rig.driver.start(options: ["pkce": "1"]))
        XCTAssertEqual(flowID, "flow-1")
        rig.setupCLI.enqueue(noSetups)
        let armed = await rig.driver.status()
        XCTAssertEqual(armed.flow, ConnectStatus.Flow(id: "flow-1", state: "waiting_for_token"))
        let busy = await rig.driver.start(options: ["code": code])
        XCTAssertEqual(busy, .failure(.busy), "one flow at a time")
        rig.setupCLI.enqueue(FakeCLILineStream.Reply(lines: [adopted]))
        rig.setupCLI.enqueue(noSetups)

        let sent = await rig.driver.submitSecret(kind: "slack_config_token", value: token)
        let data = try XCTUnwrap(success(sent))
        let json = try result(data)
        XCTAssertEqual(json["result"] as? String, "ok")
        XCTAssertEqual(json["connected"] as? Bool, false, "the update signs nobody in")
        XCTAssertEqual(json["message"] as? String, SlackConnectDriver.updatedNotConnected)
        let adopt = try XCTUnwrap(rig.setupCLI.invocations.first { $0.args.contains("adopt") })
        XCTAssertEqual(adopt.args, ["slack", "app", "adopt", "--json", "--enable-pkce"],
                       "the token's workspace; --enable-pkce only after the confirm card")
        XCTAssertEqual(adopt.stdin, Data("\(token)\n".utf8))
        XCTAssertFalse(rig.setupCLI.invocations.contains { $0.args.contains("create") })
        XCTAssertEqual(rig.child.writtenLines, [], "the update opens no sign-in")
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .failed(reason: SlackConnectDriver.updatedNotConnected),
                       "updated, but no account of the workspace is connected yet")
    }

    func testUpdateWithTheWorkspaceConnectedSaysSo() async throws {
        let adopted = #"{"result":"ok","team_id":"T0ACME","team_name":"Acme","app_id":"A0APP","client_id":"1111.2222","link_written":true}"#
        let rig = await makeRig(replies: [FakeCLILineStream.Reply(lines: [adopted]), noSetups])
        rig.accounts.accounts = [account(id: 1, team: "T0ACME", name: "Acme")]
        _ = await rig.driver.start(options: ["pkce": "1"])
        let sent = await rig.driver.submitSecret(kind: "slack_config_token", value: token)
        let json = try result(try XCTUnwrap(success(sent)))
        XCTAssertEqual(json["result"] as? String, "ok")
        XCTAssertEqual(json["connected"] as? Bool, true)
        XCTAssertEqual(json["message"] as? String, SlackConnectDriver.updated)
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .connected(account: "Acme"))
    }

    func testUpdateIgnoresAnotherAppsOrARevokedAccount() async throws {
        let adopted = #"{"result":"ok","team_id":"T0ACME","team_name":"Acme","app_id":"A0APP","client_id":"1111.2222","link_written":true}"#
        for row in [account(id: 1, team: "T0ACME", name: "Acme", client: "7777.6666"),
                    account(id: 1, team: "T0ACME", name: "Acme", status: "revoked")] {
            let rig = await makeRig(replies: [FakeCLILineStream.Reply(lines: [adopted]), noSetups])
            rig.accounts.accounts = [row]
            _ = await rig.driver.start(options: ["pkce": "1"])
            let sent = await rig.driver.submitSecret(kind: "slack_config_token", value: token)
            let json = try result(try XCTUnwrap(success(sent)))
            XCTAssertEqual(json["connected"] as? Bool, false, "\(row.clientID) \(row.status)")
            let outcome = await rig.driver.wait(flowID: "flow-1")
            XCTAssertEqual(outcome, .failed(reason: SlackConnectDriver.updatedNotConnected))
        }
    }

    func testDeclinedOrCancelledUpdateNeverAdopts() async throws {
        let rig = await makeRig(replies: [FakeCLILineStream.Reply(lines: [#"{"result":"existing_app","team_id":"T0ACME"}"#]), noSetups])
        _ = await rig.driver.start(options: ["pkce": "1"])
        await rig.driver.cancel(flowID: "flow-1")
        let outcome = await rig.driver.wait(flowID: "flow-1")
        XCTAssertEqual(outcome, .failed(reason: SlackConnectDriver.cancelled))
        _ = await rig.driver.submitSecret(kind: "slack_config_token", value: token)
        XCTAssertFalse(rig.setupCLI.invocations.contains { $0.args.contains("adopt") },
                       "a cancelled consent is gone: the token runs the create")
    }

    func testPendingCreateReportedInStatus() async {
        let record = #"{"setups":[{"team_id":"T0ACME","team_name":"Acme","app_id":"","client_id":"","connected":false,"#
            + #""link_written":false,"install_requested":false,"stage":"pending_create"},{"team_id":"T0OTHER","#
            + #""team_name":"Other","app_id":"A0X","client_id":"1.2","connected":true,"link_written":true,"#
            + #""install_requested":false,"stage":"done"}]}"#
        let rig = await makeRig(replies: [FakeCLILineStream.Reply(lines: [record])])
        rig.accounts.accounts = [account(id: 1, team: "T0OTHER", name: "Other")]
        let status = await rig.driver.status()
        XCTAssertEqual(status.setup, ConnectStatus.Setup(stage: "pending_create"))
        XCTAssertEqual(status.accounts, [ConnectStatus.Account(name: "Other", status: "ok")])
        XCTAssertEqual(rig.setupCLI.invocations.map(\.args), [["slack", "app", "status", "--json"]])
    }

    // MARK: - Slack Live

    func testLiveProbeReturnsRowStatus() async throws {
        let row = #"{"provider":"claude","status":"needs_admin","teams":[],"error_class":"","connector_id":"","checked_at":"","skipped":false}"#
        var probed = 0
        let runner = FakeCLIRunner(stdout: Data(row.utf8))
        let rig = await makeRig(runner: runner)
        let onProbed: () async -> Void = { probed += 1 }
        let driver = SlackConnectDriver(
            accounts: rig.accounts, connectFlow: rig.flow, setup: rig.setup, policy: { ManagedPolicy() }, runner: runner, onProbed: onProbed)

        let probe = await driver.liveProbe(provider: "claude")
        let data = try XCTUnwrap(success(probe))
        XCTAssertEqual(runner.invocations, [["slack", "live", "probe", "--provider", "claude", "--json"]])
        XCTAssertEqual(try result(data)["status"] as? String, "needs_admin")
        XCTAssertEqual(probed, 1, "the Connections pane re-reads the verdicts")
    }

    func testLiveProbeUnknownProviderIsTheProbesRefusal() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "--provider must be one of claude, codex, got \"other\"\n"))
        let rig = await makeRig(runner: runner)
        let refused = await rig.driver.liveProbe(provider: "other")
        XCTAssertEqual(refused, .failure(.failed(#"--provider must be one of claude, codex, got "other""#)))
        XCTAssertEqual(runner.invocations, [["slack", "live", "probe", "--provider", "other", "--json"]])
    }

    // MARK: - Writers

    func testDriverAddsNoWriter() async throws {
        let created = #"{"result":"ok","team_id":"T0ACME","team_name":"Acme","app_id":"A0APP","client_id":"1111.2222","link_written":true}"#
        let rig = await makeRig(replies: [noSetups, FakeCLILineStream.Reply(lines: [created]), noSetups, noSetups])
        // Personal connect, the token's create and status: every verb is one a button runs.
        _ = await rig.driver.status()
        _ = await rig.driver.start(options: ["code": code])
        rig.emit(.browser(flow: "f1"))
        await rig.driver.cancel(flowID: "flow-1")
        _ = await rig.driver.wait(flowID: "flow-1")
        _ = await rig.driver.submitSecret(kind: "slack_config_token", value: token)
        _ = await rig.driver.status()

        let verbs = Set(rig.setupCLI.invocations.map { $0.args.prefix(3).joined(separator: " ") })
        XCTAssertTrue(verbs.isSubset(of: ["slack app create", "slack app adopt", "slack app status"]), "\(verbs)")
        let commands = rig.child.writtenLines.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["cmd"] as? String
        }
        XCTAssertEqual(Set(commands), ["start", "cancel"], "only the connect section's commands reach the listener")
        XCTAssertEqual(rig.runner.invocations, [])
        XCTAssertEqual(rig.accounts.addCalls, 0)
    }
}
