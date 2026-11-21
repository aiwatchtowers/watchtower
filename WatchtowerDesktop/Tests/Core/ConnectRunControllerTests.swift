import Foundation
@testable import WatchtowerCore
import WatchtowerInterface
import XCTest

/// The rules of one connect assistant run (agent connect spec §5.3, §5.4,
/// §8) over a fake driver and a test clock: nothing here waits on real time.
@MainActor
final class ConnectRunControllerTests: XCTestCase {
    private var clock = ConnectTestClock()

    override func setUp() async throws {
        try await super.setUp()
        clock = ConnectTestClock()
    }

    // MARK: - Fixtures

    private func makeController(_ driver: FakeConnectDriver) -> ConnectRunController {
        ConnectRunController(driver: driver, clock: clock)
    }

    private func request(_ tool: String, _ args: String = "{}") -> ConnectWireRequest {
        ConnectWireRequest(id: 7, tool: tool, args: Data(args.utf8))
    }

    /// The answer as canonical JSON, or "error:<code>".
    private static func text(_ response: ConnectWireResponse) -> String {
        if let error = response.error { return "error:\(error.code.rawValue)" }
        return response.result.flatMap { String(bytes: $0.data, encoding: .utf8) } ?? "none"
    }

    private func call(_ controller: ConnectRunController, _ tool: String, _ args: String = "{}") async -> String {
        Self.text(await controller.handle(request(tool, args)))
    }

    /// A call that is expected to be held; `sleepers` returns once its timer runs.
    private func hold(_ controller: ConnectRunController, _ tool: String, _ args: String = "{}") -> Task<String, Never> {
        let req = request(tool, args)
        return Task { Self.text(await controller.handle(req)) }
    }

    private let waiting = #"{"state":"waiting"}"#
    private let timeout = #"{"state":"timeout"}"#

    private func pkceDriver() -> FakeConnectDriver {
        let driver = FakeConnectDriver()
        driver.confirms["pkce"] = .slackPKCE
        return driver
    }

    // MARK: - Starts

    func testSixthStartRefused() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        for n in 1...5 {
            let started = await call(controller, "connect_start")
            XCTAssertEqual(started, #"{"flow_id":"flow-\#(n)"}"#)
            let cancelled = await call(controller, "connect_cancel")
            XCTAssertEqual(cancelled, "{}")
        }
        let sixth = await call(controller, "connect_start")
        XCTAssertEqual(sixth, "error:limit")
        XCTAssertEqual(driver.starts.count, 5)
        XCTAssertEqual(controller.startsUsed, ConnectRunController.maxStarts)
    }

    func testSecondStartWhileFlowRunsIsBusy() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        let first = await call(controller, "connect_start")
        XCTAssertEqual(first, #"{"flow_id":"flow-1"}"#)
        let second = await call(controller, "connect_start")
        XCTAssertEqual(second, "error:busy")
        XCTAssertEqual(driver.starts.count, 1)
    }

    func testPolicyBlockedStartRefusedBeforeDriver() async {
        let driver = FakeConnectDriver()
        driver.allowed = false
        let controller = makeController(driver)
        let answer = await call(controller, "connect_start", #"{"pkce":true}"#)
        XCTAssertEqual(answer, "error:policy")
        XCTAssertTrue(driver.starts.isEmpty)
        XCTAssertNil(controller.pendingCard)
        XCTAssertEqual(controller.startsUsed, 0)
    }

    func testStartOptionsReachDriverAsStrings() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start", #"{"code":"https://acme.example.com/connect","dry":false}"#)
        XCTAssertEqual(driver.starts, [["code": "https://acme.example.com/connect", "dry": "false"]])
        let refused = await call(controller, "connect_start", #"{"port":993}"#)
        XCTAssertEqual(refused, "error:bad_args")
    }

    // MARK: - Confirm cards

    func testNoToolResolvesConfirm() async {
        let driver = pkceDriver()
        let controller = makeController(driver)
        let first = hold(controller, "connect_start", #"{"pkce":true}"#)
        await clock.sleepers(1)
        XCTAssertEqual(controller.pendingCard, .confirm(.slackPKCE))
        XCTAssertEqual(controller.state, .confirm(.slackPKCE))

        // Every other tool answers on its own; none presses the card.
        for (tool, args) in [("connect_status", "{}"), ("connect_cancel", "{}"), ("connect_wait", "{}"),
                             ("set_fields", #"{"confirm":"yes"}"#), ("choose", #"{"what":"jira_boards"}"#),
                             ("request_secret", #"{"kind":"slack_config_token","label":"Token"}"#),
                             ("company_publish", "{}"), ("slack_live_probe", #"{"provider":"claude"}"#)] {
            _ = await call(controller, tool, args)
        }
        // A second connect_start re-attaches to the same card.
        let second = hold(controller, "connect_start", #"{"confirm":true}"#)
        await clock.sleepers(2)
        XCTAssertEqual(controller.pendingCard, .confirm(.slackPKCE))
        XCTAssertTrue(driver.starts.isEmpty)
        XCTAssertEqual(controller.startsUsed, 0)

        controller.answerConfirm(true)
        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertEqual(firstAnswer, #"{"flow_id":"flow-1"}"#)
        XCTAssertEqual(secondAnswer, #"{"flow_id":"flow-1"}"#)
        XCTAssertEqual(driver.starts, [["pkce": "true"]])
        XCTAssertNil(controller.pendingCard)
        XCTAssertEqual(controller.startsUsed, 1)
    }

    func testDeclinedConfirmStartsNothing() async {
        let driver = pkceDriver()
        let controller = makeController(driver)
        let held = hold(controller, "connect_start", #"{"pkce":true}"#)
        await clock.sleepers(1)
        controller.answerConfirm(false)
        let answer = await held.value
        XCTAssertEqual(answer, #"{"state":"declined"}"#)
        XCTAssertTrue(driver.starts.isEmpty)
        XCTAssertEqual(controller.startsUsed, 0)
        XCTAssertNil(controller.pendingCard)
    }

    func testConfirmWaitReturnsWaitingAfterBudget() async {
        let driver = pkceDriver()
        let controller = makeController(driver)
        let first = hold(controller, "connect_start", #"{"pkce":true}"#)
        await clock.sleepers(1)
        clock.advance(by: ConnectWire.waitBudget)
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, waiting)
        XCTAssertEqual(controller.pendingCard, .confirm(.slackPKCE))

        // The re-call holds on the same card; at 44 s it is still held.
        let second = hold(controller, "connect_start", #"{"pkce":true}"#)
        await clock.sleepers(1)
        clock.advance(by: .seconds(44))
        controller.answerConfirm(true)
        let secondAnswer = await second.value
        XCTAssertEqual(secondAnswer, #"{"flow_id":"flow-1"}"#)
        XCTAssertEqual(driver.starts.count, 1)
    }

    /// Re-calls `tool` until the step's budget is spent: 19 `waiting`
    /// answers, then `timeout` on the 20th (15 minutes of 45-s calls).
    private func exhaust(_ controller: ConnectRunController, _ tool: String, _ args: String) async {
        for n in 1...ConnectRunController.maxCallsPerStep {
            let held = hold(controller, tool, args)
            await clock.sleepers(1)
            clock.advance(by: ConnectWire.waitBudget)
            let answer = await held.value
            XCTAssertEqual(answer, n < ConnectRunController.maxCallsPerStep ? waiting : timeout, "\(tool) call \(n)")
        }
        XCTAssertEqual(controller.state, .failed(.timedOut))
        XCTAssertNil(controller.pendingCard)
    }

    func testWaitBudgetExhaustedEndsWithTimeout() async {
        // A confirm-gated call.
        let confirmDriver = pkceDriver()
        let confirmRun = makeController(confirmDriver)
        await exhaust(confirmRun, "connect_start", #"{"pkce":true}"#)
        confirmRun.answerConfirm(true)  // the card is gone: nothing starts
        XCTAssertTrue(confirmDriver.starts.isEmpty)

        // request_secret.
        let secretDriver = FakeConnectDriver()
        let secretRun = makeController(secretDriver)
        await exhaust(secretRun, "request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        secretRun.sendSecret("late")
        XCTAssertTrue(secretDriver.secrets.isEmpty)

        // connect_wait: one driver wait the whole time; the abandoned flow is cancelled.
        let flowDriver = FakeConnectDriver()
        let flowRun = makeController(flowDriver)
        _ = await call(flowRun, "connect_start")
        await exhaust(flowRun, "connect_wait", "{}")
        XCTAssertEqual(flowDriver.waits, ["flow-1"])
        XCTAssertEqual(flowDriver.cancels, ["flow-1"])
        XCTAssertNil(flowRun.activeFlow)
        XCTAssertEqual(ConnectRunController.maxWaitPerStep, .seconds(900))
    }

    // MARK: - Secrets

    func testRequestSecretReturnsOnlyAfterSend() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        let held = hold(controller, "request_secret", #"{"kind":"slack_config_token","label":"Configuration access token"}"#)
        await clock.sleepers(1)
        XCTAssertEqual(controller.pendingCard, .secret(kind: "slack_config_token", label: "Configuration access token"))
        XCTAssertEqual(controller.state, .secret(label: "Configuration access token"))
        clock.advance(by: .seconds(44))
        XCTAssertTrue(driver.secrets.isEmpty)

        controller.sendSecret("xoxe-sample")
        let answer = await held.value
        XCTAssertEqual(answer, #"{"result":{"stage":"install"},"state":"sent"}"#)
        XCTAssertEqual(driver.secrets.map(\.kind), ["slack_config_token"])
        XCTAssertNil(controller.pendingCard)
    }

    func testCancelledSecretCard() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        let held = hold(controller, "request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        await clock.sleepers(1)
        controller.cancelSecret()
        let answer = await held.value
        XCTAssertEqual(answer, #"{"state":"cancelled"}"#)
        XCTAssertTrue(driver.secrets.isEmpty)
        XCTAssertNil(controller.pendingCard)
    }

    func testRequestSecretKindOutsidePlaybookRefused() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        let outside = await call(controller, "request_secret", #"{"kind":"imap_password","label":"Password"}"#)
        XCTAssertEqual(outside, "error:bad_args")
        let longLabel = String(repeating: "a", count: 81)
        let tooLong = await call(controller, "request_secret", #"{"kind":"slack_config_token","label":"\#(longLabel)"}"#)
        XCTAssertEqual(tooLong, "error:bad_args")
        XCTAssertNil(controller.pendingCard)

        // The company's Slack token comes only through company_publish.
        let company = FakeCompanyDriver()
        let companyRun = makeController(company)
        let token = await call(companyRun, "request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        XCTAssertEqual(token, "error:bad_args")
        XCTAssertNil(companyRun.pendingCard)
    }

    func testSecretNeverInResponseOrState() async throws {
        let secret = "s3cr3t-sample"
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        var lines: [Data] = []
        let req = request("request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        let held = Task { await controller.handle(req) }
        await clock.sleepers(1)
        controller.sendSecret(secret)
        lines.append(try ConnectWire.line(await held.value))
        for tool in ["connect_status", "connect_start"] {
            lines.append(try ConnectWire.line(await controller.handle(request(tool))))
        }
        XCTAssertEqual(driver.secrets.map(\.value), [secret])
        for line in lines {
            XCTAssertFalse(String(bytes: line, encoding: .utf8)?.contains(secret) ?? true)
        }
        XCTAssertNil(controller.pendingCard)
        XCTAssertFalse(String(describing: controller.state).contains(secret))
        for child in Mirror(reflecting: controller).children {
            XCTAssertFalse(String(describing: child.value).contains(secret), child.label ?? "")
        }
    }

    // MARK: - Run end, panel close, reopen

    func testRunEndDropsCardsAndClosesWaits() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let flowWait = hold(controller, "connect_wait")
        let secret = hold(controller, "request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        await clock.sleepers(2)
        XCTAssertNotNil(controller.pendingCard)

        controller.end()
        let flowAnswer = await flowWait.value
        let secretAnswer = await secret.value
        XCTAssertEqual(flowAnswer, "error:closed")
        XCTAssertEqual(secretAnswer, "error:closed")
        XCTAssertNil(controller.pendingCard)
        XCTAssertTrue(driver.cancels.isEmpty, "the flow keeps today's behaviour")
        let later = await call(controller, "connect_status")
        XCTAssertEqual(later, "error:closed")
        controller.sendSecret("late")
        XCTAssertTrue(driver.secrets.isEmpty)
    }

    /// The server cancels a call whose peer hung up (the panel closed mid
    /// turn): the call ends at once, the step stays, and the next turn's
    /// call re-attaches to the same driver wait.
    func testCancelledCallLeavesStepForNextTurn() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let first = hold(controller, "connect_wait")
        await clock.sleepers(1)
        first.cancel()
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, "error:closed")

        let second = hold(controller, "connect_wait")
        await clock.sleepers(1)
        driver.endWait(.connected(account: "acme"))
        let secondAnswer = await second.value
        XCTAssertEqual(secondAnswer, #"{"account":"acme","state":"connected"}"#)
        XCTAssertEqual(driver.waits, ["flow-1"])
    }

    /// Reopening the panel builds a new run; `connect_status` shows the flow
    /// the last one left, and `connect_wait` resumes it.
    func testReopenResumesFromStatus() async {
        let driver = FakeConnectDriver()
        driver.currentStatus = ConnectStatus(
            service: "slack", flow: .init(id: "flow-9", state: "waiting_callback"), setup: .init(stage: "pending_create"))
        let controller = makeController(driver)
        let status = await call(controller, "connect_status")
        XCTAssertEqual(status, #"{"accounts":[],"flow":{"id":"flow-9","state":"waiting_callback"},"policy_locked":false,"#
            + #""service":"slack","setup":{"stage":"pending_create"}}"#)
        let held = hold(controller, "connect_wait")
        await clock.sleepers(1)
        XCTAssertEqual(driver.waits, ["flow-9"])
        driver.currentStatus = ConnectStatus(service: "slack", accounts: [.init(name: "acme", status: "connected")])
        driver.endWait(.connected(account: "acme"))
        let answer = await held.value
        XCTAssertEqual(answer, #"{"account":"acme","state":"connected"}"#)
        XCTAssertEqual(controller.state, .done(accounts: 1, noun: .workspace))
    }

    // MARK: - Company

    func testCompanyDraftReadHidesBothSecrets() async {
        let company = FakeCompanyDriver()
        company.draft = Data("""
        {"company":"Acme","vendors":{
          "google":{"client_id":"acme.apps.googleusercontent.com","client_secret":"g-secret-sample","client_secret_set":true},
          "atlassian":{"client_id":"acme-client","site":"acme.atlassian.net","client_secret":"a-secret-sample","client_secret_set":true}}}
        """.utf8)
        let controller = makeController(company)
        let read = await call(controller, "company_draft")
        XCTAssertFalse(read.contains("g-secret-sample"))
        XCTAssertFalse(read.contains("a-secret-sample"))
        XCTAssertEqual(read.components(separatedBy: #""client_secret_set":true"#).count - 1, 2)
        XCTAssertFalse(read.contains(#""client_secret":"#))
    }

    func testCompanyPublishConfirmThenTokenCard() async {
        let company = FakeCompanyDriver()
        let controller = makeController(company)
        let held = hold(controller, "company_publish")
        await clock.sleepers(1)
        XCTAssertEqual(controller.pendingCard, .confirm(.companyPublish(company: "Acme")))
        controller.answerConfirm(true)
        XCTAssertEqual(controller.pendingCard, .secret(kind: "slack_config_token", label: ConnectRunController.publishTokenLabel))
        XCTAssertTrue(company.published.isEmpty)
        controller.sendSecret("xoxe-sample")
        let answer = await held.value
        XCTAssertEqual(answer, #"{"published":true}"#)
        XCTAssertEqual(company.published, ["xoxe-sample"])
        XCTAssertTrue(company.secrets.isEmpty, "the token goes to publish, not submitSecret")

        let declined = hold(controller, "company_publish")
        await clock.sleepers(1)
        controller.answerConfirm(false)
        let declinedAnswer = await declined.value
        XCTAssertEqual(declinedAnswer, #"{"state":"declined"}"#)
        XCTAssertEqual(company.published.count, 1)
    }

    func testCompanyCheckWaitsAndReattaches() async {
        let company = FakeCompanyDriver()
        let controller = makeController(company)
        let first = hold(controller, "company_check", #"{"vendor":"google"}"#)
        await clock.sleepers(1)
        XCTAssertEqual(controller.state, .waiting(step: ConnectRunController.checkWaitStep))
        clock.advance(by: ConnectWire.waitBudget)
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, waiting)

        let other = await call(controller, "company_check", #"{"vendor":"atlassian"}"#)
        XCTAssertEqual(other, "error:busy")
        let second = hold(controller, "company_check", #"{"vendor":"google"}"#)
        await clock.sleepers(1)
        company.endCheck(.success(Data(#"{"ok":true}"#.utf8)))
        let secondAnswer = await second.value
        XCTAssertEqual(secondAnswer, #"{"ok":true}"#)
        XCTAssertEqual(company.checks, ["google"])
        XCTAssertEqual(controller.state, .thinking)
    }

    // MARK: - Routing

    func testLiveProbeRoutedOnlyToProbingDriver() async {
        let prober = FakeProbingDriver()
        let probeRun = makeController(prober)
        let probed = await call(probeRun, "slack_live_probe", #"{"provider":"codex"}"#)
        XCTAssertEqual(probed, #"{"status":"ok"}"#)
        XCTAssertEqual(prober.probes, ["codex"])
        let badProvider = await call(probeRun, "slack_live_probe", #"{"provider":"gemini"}"#)
        XCTAssertEqual(badProvider, "error:bad_args")

        let plain = makeController(FakeConnectDriver())
        let refused = await call(plain, "slack_live_probe", #"{"provider":"claude"}"#)
        XCTAssertEqual(refused, "error:unknown_tool")
    }

    func testUnknownToolRefused() async {
        let controller = makeController(FakeConnectDriver())
        for tool in ["frobnicate", "company_draft", "company_check", "company_publish"] {
            let answer = await call(controller, tool, #"{"vendor":"google"}"#)
            XCTAssertEqual(answer, "error:unknown_tool", tool)
        }
        let notObject = await call(controller, "connect_status", "[]")
        XCTAssertEqual(notObject, "error:bad_args")
    }

    func testFieldsAndChoices() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        let set = await call(controller, "set_fields", #"{"host":"imap.example.com","port":"993"}"#)
        XCTAssertEqual(set, "{}")
        XCTAssertEqual(driver.fields, [["host": "imap.example.com", "port": "993"]])
        let notString = await call(controller, "set_fields", #"{"port":993}"#)
        XCTAssertEqual(notString, "error:bad_args")
        let chosen = await call(controller, "choose", #"{"what":"jira_boards","select":["10"]}"#)
        XCTAssertEqual(chosen, #"{"items":[{"id":"10","name":"Acme board","selected":true}]}"#)
    }

    // MARK: - Review fixes

    private let connected = #"{"account":"acme","state":"connected"}"#

    /// A driver whose `wait` answers `.waiting` early is asked again while
    /// the call is held; the call is not woken, so re-calls stay 45 s apart.
    func testDriverEarlyWaitingKeepsCallHeld() async {
        let driver = FakeConnectDriver()
        driver.waitAnswers = [.waiting, .waiting, .waiting]
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let held = hold(controller, "connect_wait")
        for _ in 1...3 {
            await clock.sleepers(2)  // the call's 45-s timer and the re-poll pause
            clock.advance(by: ConnectRunController.repollPause)
        }
        await driver.until { driver.isWaiting }
        driver.endWait(.connected(account: "acme"))
        let answer = await held.value
        XCTAssertEqual(answer, connected)
        XCTAssertEqual(driver.waits, ["flow-1", "flow-1", "flow-1", "flow-1"])
    }

    func testSetFieldsRefusesEnable() async {
        let driver = FakeConnectDriver(service: "quickConnections", secretKinds: [])
        let controller = makeController(driver)
        for args in [#"{"enable":"true"}"#, #"{"command":"acme-mcp","Enable":"yes"}"#] {
            let answer = await call(controller, "set_fields", args)
            XCTAssertEqual(answer, "error:bad_args", args)
        }
        XCTAssertTrue(driver.fields.isEmpty)
        XCTAssertNil(controller.pendingCard)
    }

    func testCompanyCheckThatReplacesNeedsConfirm() async {
        let company = FakeCompanyDriver()
        company.confirms["company_check:slack"] = .companyReplace(company: "Acme")
        let controller = makeController(company)
        let held = hold(controller, "company_check", #"{"vendor":"slack"}"#)
        await clock.sleepers(1)
        XCTAssertEqual(controller.pendingCard, .confirm(.companyReplace(company: "Acme")))
        XCTAssertTrue(company.checks.isEmpty)
        let other = await call(controller, "company_publish")
        XCTAssertEqual(other, "error:busy", "a card is open")

        controller.answerConfirm(true)
        XCTAssertNil(controller.pendingCard)
        await company.until { company.isChecking }
        XCTAssertEqual(company.checks, ["slack"])
        company.endCheck(.success(Data(#"{"ok":true}"#.utf8)))
        let answer = await held.value
        XCTAssertEqual(answer, #"{"ok":true}"#)

        let declined = hold(controller, "company_check", #"{"vendor":"slack"}"#)
        await clock.sleepers(1)
        controller.answerConfirm(false)
        let declinedAnswer = await declined.value
        XCTAssertEqual(declinedAnswer, #"{"state":"declined"}"#)
        XCTAssertEqual(company.checks, ["slack"])
    }

    /// A flow that ends while no call is held keeps its answer for the next
    /// `connect_wait`, even though the status no longer shows the flow.
    func testFlowEndedBetweenCallsIsKept() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let first = hold(controller, "connect_wait")
        await clock.sleepers(1)
        clock.advance(by: ConnectWire.waitBudget)
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, waiting)

        driver.endWait(.connected(account: "acme"))
        while controller.activeFlow != nil { await Task.yield() }
        XCTAssertNil(driver.currentStatus.flow)
        let second = await call(controller, "connect_wait")
        XCTAssertEqual(second, connected)
    }

    /// The flow connects while the account count is still being read: the
    /// call gets `connected` at once.
    func testConnectedAnswerDoesNotWaitOnStatus() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let held = hold(controller, "connect_wait")
        await clock.sleepers(1)
        driver.holdStatus = true
        driver.endWait(.connected(account: "acme"))
        await driver.until { !driver.heldStatus.isEmpty }
        clock.advance(by: ConnectWire.waitBudget)
        let answer = await held.value
        XCTAssertEqual(answer, connected)
        driver.releaseStatus()
    }

    func testNoNewCardAfterTimeout() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        await exhaust(controller, "request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        for tool in ["request_secret", "connect_start", "connect_wait"] {
            let answer = await call(controller, tool, tool == "request_secret" ? #"{"kind":"slack_config_token","label":"Again"}"# : "{}")
            XCTAssertEqual(answer, "error:closed", tool)
        }
        XCTAssertNil(controller.pendingCard)
        XCTAssertEqual(controller.state, .failed(.timedOut))
        XCTAssertTrue(driver.starts.isEmpty)
        let status = await call(controller, "connect_status")
        XCTAssertTrue(status.hasPrefix("{"), "a read still answers")
    }

    func testEndWhileStatusPendingCreatesNoWait() async {
        let driver = FakeConnectDriver()
        driver.setFlow("flow-9")
        driver.holdStatus = true
        let controller = makeController(driver)
        let held = hold(controller, "connect_wait")
        await driver.until { !driver.heldStatus.isEmpty }
        controller.end()
        driver.releaseStatus()
        let answer = await held.value
        XCTAssertEqual(answer, "error:closed")
        XCTAssertTrue(driver.waits.isEmpty)
        XCTAssertNil(controller.activeFlow)
    }

    /// A flow adopted while the PKCE card was open: confirming starts no
    /// second flow and costs no start.
    func testConfirmedStartRechecksFlow() async {
        let driver = pkceDriver()
        let controller = makeController(driver)
        let start = hold(controller, "connect_start", #"{"pkce":true}"#)
        await clock.sleepers(1)
        driver.setFlow("flow-9")
        let flowWait = hold(controller, "connect_wait")
        await clock.sleepers(2)
        controller.answerConfirm(true)
        let startAnswer = await start.value
        XCTAssertEqual(startAnswer, "error:busy")
        XCTAssertTrue(driver.starts.isEmpty)
        XCTAssertEqual(controller.startsUsed, 0)
        controller.end()
        _ = await flowWait.value
    }

    func testStartNotBusyAfterFlowEndedElsewhere() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        let first = await call(controller, "connect_start")
        XCTAssertEqual(first, #"{"flow_id":"flow-1"}"#)
        driver.setFlow(nil)  // cancelled in another window
        let second = await call(controller, "connect_start")
        XCTAssertEqual(second, #"{"flow_id":"flow-2"}"#)
        XCTAssertEqual(driver.starts.count, 2)
    }

    func testFinishedCheckDoesNotBlockOtherVendor() async {
        let company = FakeCompanyDriver()
        let controller = makeController(company)
        let first = hold(controller, "company_check", #"{"vendor":"google"}"#)
        await clock.sleepers(1)
        clock.advance(by: ConnectWire.waitBudget)
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, waiting)
        company.endCheck(.success(Data(#"{"ok":true}"#.utf8)))  // never collected
        while controller.state != .thinking { await Task.yield() }

        let second = hold(controller, "company_check", #"{"vendor":"atlassian"}"#)
        await company.until { company.isChecking }
        XCTAssertEqual(company.checks, ["google", "atlassian"])
        company.endCheck(.success(Data(#"{"ok":"atlassian"}"#.utf8)))
        let secondAnswer = await second.value
        XCTAssertEqual(secondAnswer, #"{"ok":"atlassian"}"#)
    }

    // MARK: - Flow identity

    /// A status snapshot taken before a start finished must not wipe the
    /// new flow: the next start stays busy and never reaches the driver.
    func testStaleStatusKeepsNewerFlow() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        _ = await call(controller, "connect_cancel")
        driver.holdStatus = true
        let status = hold(controller, "connect_status")  // its snapshot shows no flow
        await driver.until { !driver.heldStatus.isEmpty }
        driver.holdStatus = false
        let started = await call(controller, "connect_start")
        XCTAssertEqual(started, #"{"flow_id":"flow-2"}"#)
        driver.releaseStatus()
        _ = await status.value
        XCTAssertEqual(controller.activeFlow, "flow-2")
        let again = await call(controller, "connect_start")
        XCTAssertEqual(again, "error:busy")
        XCTAssertEqual(driver.starts.count, 2)
    }

    /// The flow ended elsewhere while a connect_wait was held on it: a newer
    /// start that succeeds answers that call `failed` and retires its wait,
    /// so it cannot time the run out; the new flow gets a wait of its own.
    func testReconciledFlowAnswersHeldWait() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let old = hold(controller, "connect_wait")
        await clock.sleepers(1)
        await driver.until { driver.isWaiting }
        driver.setFlow(nil)  // cancelled in another window; the driver's wait has not noticed
        let started = await call(controller, "connect_start")
        XCTAssertEqual(started, #"{"flow_id":"flow-2"}"#)
        let oldAnswer = await old.value
        XCTAssertEqual(oldAnswer, #"{"reason":"a newer sign-in replaced this one","state":"failed"}"#)

        let new = hold(controller, "connect_wait")
        await clock.sleepers(1)
        await driver.until { driver.waits.count == 2 }
        driver.endWait(.connected(account: "acme"))
        let newAnswer = await new.value
        XCTAssertEqual(newAnswer, connected)
        XCTAssertEqual(driver.waits, ["flow-1", "flow-2"])
        XCTAssertNotEqual(controller.state, .failed(.timedOut))
    }

    /// A status without the flow, read while its wait runs, is no failure:
    /// the wait's own `connected` answers the held call.
    func testFlowLeavingStatusKeepsItsWait() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let held = hold(controller, "connect_wait")
        await clock.sleepers(1)
        await driver.until { driver.isWaiting }
        driver.setFlow(nil)  // the sign-in finished and left the status first
        driver.currentStatus = ConnectStatus(service: "slack", accounts: [.init(name: "acme", status: "connected")])
        let status = await call(controller, "connect_status")
        XCTAssertTrue(status.contains(#""flow":null"#))
        XCTAssertNil(controller.activeFlow)
        XCTAssertEqual(controller.state, .waiting(step: ConnectRunController.flowWaitStep))

        driver.endWait(.connected(account: "acme"))
        let answer = await held.value
        XCTAssertEqual(answer, connected)
        await driver.until { driver.statusAnswers == 2 }  // the count read after connected
        XCTAssertEqual(controller.state, .done(accounts: 1, noun: .workspace))
    }

    /// A newer flow that starts and is cancelled before any wait does not
    /// bring back the older flow's uncollected answer.
    func testOldAnswerGoneAfterNewerStartCancelled() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let first = hold(controller, "connect_wait")
        await clock.sleepers(1)
        clock.advance(by: ConnectWire.waitBudget)
        _ = await first.value
        driver.endWait(.failed(reason: "Slack denied the sign-in"))  // nobody collects it
        while controller.activeFlow != nil { await Task.yield() }

        let started = await call(controller, "connect_start")
        XCTAssertEqual(started, #"{"flow_id":"flow-2"}"#)
        let cancelled = await call(controller, "connect_cancel")
        XCTAssertEqual(cancelled, "{}")
        let answer = await call(controller, "connect_wait")
        XCTAssertEqual(answer, "error:failed", "no sign-in runs; the old answer is gone")
    }

    /// An older flow's uncollected answer is never replayed for a newer flow.
    func testOldFlowAnswerNotReplayedForNewFlow() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let first = hold(controller, "connect_wait")
        await clock.sleepers(1)
        clock.advance(by: ConnectWire.waitBudget)
        _ = await first.value
        driver.endWait(.failed(reason: "Slack denied the sign-in"))  // nobody collects it
        while controller.activeFlow != nil { await Task.yield() }

        let started = await call(controller, "connect_start")
        XCTAssertEqual(started, #"{"flow_id":"flow-2"}"#)
        let held = hold(controller, "connect_wait")
        await clock.sleepers(1)
        await driver.until { driver.waits.count == 2 }
        driver.endWait(.connected(account: "acme"))
        let answer = await held.value
        XCTAssertEqual(answer, connected)
    }

    func testTimeoutClearsEveryOpenCard() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let secret = hold(controller, "request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)
        await clock.sleepers(1)
        clock.advance(by: ConnectWire.waitBudget)
        let secretAnswer = await secret.value
        XCTAssertEqual(secretAnswer, waiting)
        XCTAssertNotNil(controller.pendingCard)

        await exhaust(controller, "connect_wait", "{}")  // the flow step times out
        XCTAssertNil(controller.pendingCard)
        controller.sendSecret("late")
        XCTAssertTrue(driver.secrets.isEmpty)
    }

    func testLateStartAfterEndLeavesStateAlone() async {
        let driver = pkceDriver()
        let controller = makeController(driver)
        let held = hold(controller, "connect_start", #"{"pkce":true}"#)
        await clock.sleepers(1)
        controller.answerConfirm(true)  // the start runs in a task of its own
        controller.end()
        let answer = await held.value
        XCTAssertEqual(answer, "error:closed")
        await driver.until { driver.starts.count == 1 }
        XCTAssertNil(controller.activeFlow)
        XCTAssertEqual(controller.state, .thinking)
    }

    /// The account count read after `connected` lands after a newer start:
    /// it does not put the panel back to done.
    func testLateAccountCountAfterNewerStart() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        _ = await call(controller, "connect_start")
        let held = hold(controller, "connect_wait")
        await clock.sleepers(1)
        await driver.until { driver.isWaiting }
        driver.holdStatus = true
        driver.endWait(.connected(account: "acme"))
        let answer = await held.value
        XCTAssertEqual(answer, connected)
        await driver.until { !driver.heldStatus.isEmpty }
        let started = await call(controller, "connect_start")
        XCTAssertEqual(started, #"{"flow_id":"flow-2"}"#)
        let answered = driver.statusAnswers
        driver.releaseStatus()
        // The held read returns into the controller, which decides in the
        // same main-actor step before this test resumes.
        await driver.until { driver.statusAnswers == answered + 1 }
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(controller.activeFlow, "flow-2")
    }

    // MARK: - State

    func testStateMapping() async {
        let driver = FakeConnectDriver()
        let controller = makeController(driver)
        XCTAssertEqual(controller.state, .thinking)

        driver.startResults = [.failure(.busy)]
        let busy = await call(controller, "connect_start")
        XCTAssertEqual(busy, "error:busy")
        XCTAssertEqual(controller.state, .busy)

        _ = await call(controller, "connect_start")
        XCTAssertEqual(controller.state, .thinking)
        let held = hold(controller, "connect_wait")
        await clock.sleepers(1)
        XCTAssertEqual(controller.state, .waiting(step: ConnectRunController.flowWaitStep))
        driver.endWait(.failed(reason: "Slack denied the sign-in"))
        let failed = await held.value
        XCTAssertEqual(failed, #"{"reason":"Slack denied the sign-in","state":"failed"}"#)
        XCTAssertEqual(controller.state, .thinking)

        _ = await call(controller, "connect_start")
        driver.currentStatus = ConnectStatus(service: "slack", accounts: [
            .init(name: "acme", status: "connected"), .init(name: "acme-two", status: "connected")
        ])
        let connected = hold(controller, "connect_wait")
        await clock.sleepers(1)
        driver.endWait(.connected(account: "acme-two"))
        _ = await connected.value
        XCTAssertEqual(controller.state, .done(accounts: 2, noun: .workspace))

        // The driver's own early `waiting` keeps the call held until its 45 s.
        _ = await call(controller, "connect_start")
        let quick = hold(controller, "connect_wait")
        await clock.sleepers(1)
        driver.endWait(.waiting)
        await clock.sleepers(2)
        clock.advance(by: ConnectWire.waitBudget)
        let quickAnswer = await quick.value
        XCTAssertEqual(quickAnswer, waiting)
        controller.end()

        XCTAssertEqual(ConnectRunController.noun("jira"), .site)
        XCTAssertEqual(ConnectRunController.noun("google"), .account)
    }

    // MARK: - Wire parity

    /// …/internal/connectwire/testdata, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("internal/connectwire/testdata")

    /// Every response case's result decodes into the Swift type its shape
    /// names and encodes back to the same JSON value: a key either side
    /// adds, drops or renames fails here.
    func testResultShapesMatchWireCases() throws {
        struct Case: Decodable {
            let name: String
            let kind: String
            let shape: String?
            let line: String
        }
        struct File: Decodable { let cases: [Case] }
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("wire_cases.json"))
        let cases = try JSONDecoder().decode(File.self, from: data).cases
        var seen: Set<String> = []
        for wireCase in cases where wireCase.kind == "response" {
            let response = try JSONDecoder().decode(ConnectWireResponse.self, from: Data(wireCase.line.utf8))
            guard let shape = wireCase.shape, let result = response.result else { continue }
            seen.insert(shape)
            let encoded: Data = switch shape {
            case "status": try Self.reencode(ConnectStatus.self, result)
            case "started": try Self.reencode(ConnectStarted.self, result)
            case "waited": try Self.reencode(ConnectWaited.self, result)
            case "secret": try Self.reencode(ConnectSecretSent.self, result)
            case "pending": try Self.reencode(ConnectPending.self, result)
            case "choices": try Self.reencode(ConnectChoices.self, result)
            case "company_draft": try Self.reencode(ConnectCompanyDraft.self, result)
            case "done": try Self.reencode(ConnectDone.self, result)
            default: Data()
            }
            XCTAssertEqual(String(bytes: try RawJSON(data: encoded).data, encoding: .utf8),
                           String(bytes: result.data, encoding: .utf8), wireCase.name)
        }
        XCTAssertEqual(seen, ["status", "started", "waited", "secret", "pending", "choices", "company_draft", "done"])
    }

    private static func reencode<T: Codable>(_ type: T.Type, _ raw: RawJSON) throws -> Data {
        try JSONEncoder().encode(JSONDecoder().decode(T.self, from: raw.data))
    }
}
