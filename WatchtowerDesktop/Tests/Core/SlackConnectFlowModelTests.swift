import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The connect flow of screens spec §4.3 (plan B Task 14) over a real
/// listener host on a fake child: events are fed through the host's handler
/// (`emit`), commands are read off the child's stdin.
@MainActor
final class SlackConnectFlowModelTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let target = SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222")
    private let link = "http://127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222"

    @MainActor
    private struct Rig {
        let model: SlackConnectFlowModel
        let host: SlackConnectListenerHost
        let child: FakeCLILineSession

        func emit(_ event: SlackConnectEvent) { host.onEvent?(event) }
        var sent: [String] { child.writtenLines }
    }

    private func makeRig() async -> Rig {
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let now = clock
        let model = SlackConnectFlowModel(host: host) { now }
        host.ensureRunning()
        let child = await fake.session(number: 1)
        child.emit(#"{"event":"listening","port":18551}"#)
        await untilObserved { host.state == .listening }
        return Rig(model: model, host: host, child: child)
    }

    private let startLine = #"{"client_id":"1111.2222","cmd":"start","team_id":"T0ACME"}"#

    /// A pasted code, answered with `browser(f1)`.
    private func inBrowser(_ rig: Rig) {
        rig.model.pasteText = "T0ACME:1111.2222"
        XCTAssertTrue(rig.model.connectPasted())
        rig.emit(.browser(flow: "f1"))
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
    }

    // MARK: - States

    func testFreshModelIsIdle() async {
        let rig = await makeRig()
        XCTAssertEqual(rig.model.step, .idle)
        XCTAssertNil(rig.model.sheet)
        XCTAssertFalse(rig.model.showsSheet)
        XCTAssertTrue(rig.model.canStart)
        XCTAssertEqual(rig.model.pasteText, "")
        XCTAssertNil(rig.model.pasteError)
        XCTAssertEqual(rig.sent, [], "nothing goes to the child before the owner acts")
    }

    func testWaitingLineAfterFiveMinutes() async {
        let rig = await makeRig()
        inBrowser(rig)
        let start = clock
        XCTAssertNil(rig.model.waitingLine(at: start.addingTimeInterval(4 * 60)))
        XCTAssertNil(rig.model.waitingLine(at: start.addingTimeInterval(5 * 60 - 1)))
        XCTAssertEqual(rig.model.waitingLine(at: start.addingTimeInterval(5 * 60)), "Waiting for Slack since 5 min")
        XCTAssertEqual(rig.model.waitingLine(at: start.addingTimeInterval(12 * 60)), "Waiting for Slack since 12 min")
        XCTAssertEqual(rig.model.waitingLine(at: start.addingTimeInterval(3 * 3600)), "Waiting for Slack since 3 h")
        XCTAssertEqual(rig.model.sheet?.buttons.map(\.action), [.cancel], "Cancel stays; no deadline (A22)")
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: start))
    }

    func testLinkStartsAtConfirm() async {
        let rig = await makeRig()
        var forward = 0
        rig.model.onLink = { forward += 1 }
        rig.emit(.link(flow: "f1", teamID: "T0ACME", clientID: "1111.2222"))

        XCTAssertEqual(rig.model.step, .confirming(flow: "f1", target: target))
        XCTAssertEqual(forward, 1, "the app comes forward with the confirm")
        XCTAssertEqual(rig.sent, [], "nothing reaches Slack before Connect")
        XCTAssertEqual(rig.model.sheet?.buttons.map(\.title), ["Cancel", "Connect"])

        rig.model.confirm()
        XCTAssertEqual(rig.sent, [#"{"cmd":"confirm","flow":"f1"}"#])
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
        rig.emit(.browser(flow: "f1"))
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
    }

    func testPasteSkipsConfirm() async {
        let rig = await makeRig()
        rig.model.pasteText = "  \(link)\n"
        XCTAssertTrue(rig.model.connectPasted())
        XCTAssertEqual(rig.sent, [startLine])
        XCTAssertEqual(rig.model.step, .starting(target))
        XCTAssertEqual(rig.model.pasteText, "", "the field clears once the flow starts")
        XCTAssertEqual(rig.model.sheet?.body, "Finish in your browser: Slack asks you to allow Watchtower.")

        rig.emit(.browser(flow: "f1"))
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 3, teamID: "T0ACME", teamName: "acme", reboundFrom: "")))
        XCTAssertEqual(rig.model.step, .connected(workspace: "acme"))
    }

    func testMDMConnectSkipsConfirm() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        XCTAssertEqual(rig.sent, [startLine])
        XCTAssertEqual(rig.model.step, .starting(target))
    }

    func testSecondLinkWhileRunningIsRefused() async {
        let rig = await makeRig()
        inBrowser(rig)
        rig.emit(.link(flow: "f2", teamID: "T0OTHER", clientID: "3333.4444"))
        XCTAssertEqual(rig.sent, [startLine, #"{"cmd":"cancel","flow":"f2"}"#],
                       "no confirm or start; the link that is not shown is cancelled")
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock), "keeps the sheet")
        let before = rig.sent

        // A start while the flow runs is refused too.
        XCTAssertFalse(rig.model.start(SlackConnectTarget(teamID: "T0OTHER", clientID: "3333.4444")))
        rig.model.pasteText = "T0OTHER:3333.4444"
        XCTAssertFalse(rig.model.connectPasted())
        XCTAssertEqual(rig.sent, before)

        // On the confirm, a second link is refused the same way.
        let other = await makeRig()
        other.emit(.link(flow: "f1", teamID: "T0ACME", clientID: "1111.2222"))
        other.emit(.link(flow: "f2", teamID: "T0OTHER", clientID: "3333.4444"))
        XCTAssertEqual(other.model.step, .confirming(flow: "f1", target: target))
        XCTAssertEqual(other.sent, [#"{"cmd":"cancel","flow":"f2"}"#])
        other.emit(.failed(flow: "f2", reason: .cancelled, message: ""))
        XCTAssertEqual(other.model.step, .confirming(flow: "f1", target: target), "its cancel answer shows nothing")
    }

    /// A link the child took just before our `start` reached it would refuse
    /// that start forever (A22: no deadline): it is cancelled.
    func testLinkRacingOurStartIsCancelled() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.link(flow: "f9", teamID: "T0OTHER", clientID: "3333.4444"))
        XCTAssertEqual(rig.sent, [startLine, #"{"cmd":"cancel","flow":"f9"}"#])
        rig.emit(.busy(flow: "f9"))
        XCTAssertEqual(rig.model.sheet?.body,
                       "Could not connect: another Slack connection is still running. Nothing was saved.")
        rig.emit(.failed(flow: "f9", reason: .cancelled, message: "cancelled"))
        XCTAssertEqual(rig.model.sheet?.buttons.map(\.action), [.close, .startAgain])
    }

    /// A20: a company link or code in Slack's field goes to the company flow;
    /// its refusal is this field's error, and a Slack code never goes there.
    func testCompanyCodeGoesToTheCompanyFlow() async {
        let rig = await makeRig()
        var handed: [String] = []
        var answer: String? = "That is not a Watchtower company code."
        rig.model.companyPaste = { text in
            handed.append(text)
            return answer
        }
        let code = "eyJ2IjoxLCJjb21wYW55IjoiQWNtZSJ9"
        rig.model.pasteText = code
        XCTAssertTrue(rig.model.connectPasted())
        await untilObserved { rig.model.pasteError != nil }
        XCTAssertEqual(handed, [code])
        XCTAssertEqual(rig.model.pasteError, "That is not a Watchtower company code.")
        XCTAssertEqual(rig.sent, [], "no Slack flow starts")

        answer = nil
        rig.model.pasteText = "http://127.0.0.1:18551/company/connect?b=\(code)"
        XCTAssertTrue(rig.model.connectPasted())
        await untilObserved { rig.model.pasteText.isEmpty }
        XCTAssertNil(rig.model.pasteError)
        XCTAssertEqual(handed.count, 2)

        rig.model.pasteText = "T0ACME:1111.2222"
        XCTAssertTrue(rig.model.connectPasted())
        XCTAssertEqual(handed.count, 2, "a Slack code stays Slack's")
    }

    func testPasteRejectsOtherText() async {
        let rig = await makeRig()
        let refused = [
            "", "hello", "https://acme.slack.com/apps/A0ACME", "T0ACME", "t0acme:1111.2222", "T0ACME:1111",
            "T0ACME:1111.2222.3", "U0ACME:1111.2222",
            "https://127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222",
            "http://localhost:18551/slack/connect?team=T0ACME&client=1111.2222",
            "http://127.0.0.1:18552/slack/connect?team=T0ACME&client=1111.2222",
            "http://127.0.0.1:18551/callback?team=T0ACME&client=1111.2222",
            "http://127.0.0.1:18551/slack/connect?team=T0ACME&team=T0OTHER&client=1111.2222",
            "http://127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222#x",
            "http://user@127.0.0.1:18551/slack/connect?team=T0ACME&client=1111.2222"
        ]
        for text in refused {
            rig.model.pasteText = text
            XCTAssertFalse(rig.model.connectPasted(), text)
            XCTAssertEqual(rig.model.pasteError,
                           "That is not a Watchtower connect link or code. Copy it again from the app's About tab in Slack.",
                           text)
        }
        XCTAssertEqual(rig.sent, [], "nothing starts")
        XCTAssertEqual(rig.model.step, .idle)
        rig.model.pasteText = "T0ACME:1"
        XCTAssertNil(rig.model.pasteError, "editing the field clears the error")

        XCTAssertEqual(SlackConnectTarget.parse("E0ACME:1.2"), SlackConnectTarget(teamID: "E0ACME", clientID: "1.2"))
        XCTAssertEqual(SlackConnectTarget.parse(link), target)
        XCTAssertEqual(SlackConnectTarget.parse(link + "&extra=1"), target, "Go ignores other parameters too")
    }

    func testMismatchAndDeniedStates() async {
        let rig = await makeRig()
        inBrowser(rig)
        rig.emit(.failed(flow: "f1", reason: .teamMismatch, message: "Slack signed you in to T0OTHER"))
        XCTAssertEqual(rig.model.step, .failed(.teamMismatch, retry: target))
        XCTAssertEqual(rig.model.sheet?.body,
                       "Slack signed you in to a different workspace than the link names. Nothing was saved.")
        XCTAssertEqual(rig.model.sheet?.icon, .warning)
        XCTAssertEqual(rig.model.sheet?.buttons.map(\.title), ["Close", "Start again"])

        // Start again goes straight to Slack (skip-confirm), same target.
        rig.model.startAgain()
        XCTAssertEqual(rig.sent, [startLine, startLine])
        rig.emit(.browser(flow: "f2"))
        rig.emit(.failed(flow: "f2", reason: .denied, message: "access_denied"))
        XCTAssertEqual(rig.model.step, .failed(.denied, retry: target))
        XCTAssertEqual(rig.model.sheet?.body, "You did not allow Watchtower in Slack. Nothing was saved.")
        XCTAssertEqual(rig.model.sheet?.icon, .denied)

        rig.model.dismiss()
        XCTAssertEqual(rig.model.step, .idle)

        // Any other reason names Go's message once, with one full stop.
        rig.model.startAgain() // nothing to start again from idle
        XCTAssertEqual(rig.sent.count, 2)
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.browser(flow: "f3"))
        rig.emit(.failed(flow: "f3", reason: .exchange, message: "Slack refused the code."))
        XCTAssertEqual(rig.model.sheet?.body, "Could not connect: Slack refused the code. Nothing was saved.")
    }

    func testCancelSendsCancel() async {
        let rig = await makeRig()
        inBrowser(rig)
        rig.model.cancel()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"cancel","flow":"f1"}"#)
        XCTAssertEqual(rig.model.step, .idle, "the sheet closes at once")
        rig.emit(.failed(flow: "f1", reason: .cancelled, message: "This connection was cancelled in Watchtower."))
        XCTAssertEqual(rig.model.step, .idle, "the expected cancel answer shows nothing")

        // Cancel on the confirm.
        rig.emit(.link(flow: "f2", teamID: "T0ACME", clientID: "1111.2222"))
        rig.model.cancel()
        XCTAssertEqual(rig.sent.last, #"{"cmd":"cancel","flow":"f2"}"#)
        XCTAssertEqual(rig.model.step, .idle)
    }

    /// The callback won the race with Cancel: the account is written, so the
    /// success shows and the accounts reload.
    func testConnectedAfterCancelIsAccepted() async {
        let rig = await makeRig()
        var written: [Int64] = []
        rig.model.onConnected = { written.append($0.accountID) }
        inBrowser(rig)
        rig.model.cancel()
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 4, teamID: "T0ACME", teamName: "", reboundFrom: "")))
        XCTAssertEqual(rig.model.step, .connected(workspace: "T0ACME"), "an unnamed team shows its id")
        XCTAssertEqual(rig.model.sheet?.title, "Connected to T0ACME")
        XCTAssertEqual(written, [4])
    }

    /// Cancel before the child named the flow: the cancel goes out once it does.
    func testCancelBeforeFlowIDCancelsOnceNamed() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.model.cancel()
        XCTAssertEqual(rig.model.step, .idle)
        XCTAssertFalse(rig.model.canStart, "the started flow is still unanswered")
        XCTAssertEqual(rig.sent, [startLine])
        rig.emit(.browser(flow: "f1"))
        XCTAssertEqual(rig.sent, [startLine, #"{"cmd":"cancel","flow":"f1"}"#])
        XCTAssertEqual(rig.model.step, .idle)
        XCTAssertTrue(rig.model.canStart)
        rig.emit(.failed(flow: "f1", reason: .cancelled, message: ""))
        XCTAssertEqual(rig.model.step, .idle)
    }

    /// A refused start carries no flow id; it answers the latest start.
    func testFailedWithEmptyFlowAnswersStart() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.failed(flow: "", reason: .purgeRunning, message: "Its data is being deleted."))
        XCTAssertEqual(rig.model.step, .failed(.other("Its data is being deleted"), retry: target))

        // Not starting: an empty-flow failure is someone else's, dropped.
        rig.model.dismiss()
        rig.emit(.failed(flow: "", reason: .policy, message: "Blocked."))
        XCTAssertEqual(rig.model.step, .idle)
    }

    func testUnknownFlowsAreDropped() async {
        let rig = await makeRig()
        rig.emit(.browser(flow: "zz"))
        XCTAssertEqual(rig.sent, [#"{"cmd":"cancel","flow":"zz"}"#],
                       "a browser flow nobody here owns is cancelled: it has no deadline (A22)")
        rig.emit(.connected(SlackConnectedAccount(flow: "zz", accountID: 9, teamID: "T0ACME", teamName: "acme", reboundFrom: "")))
        rig.emit(.failed(flow: "zz", reason: .denied, message: ""))
        rig.emit(.busy(flow: "zz"))
        XCTAssertEqual(rig.model.step, .idle)
        inBrowser(rig)
        rig.emit(.failed(flow: "zz", reason: .denied, message: ""))
        rig.emit(.connected(SlackConnectedAccount(flow: "zz", accountID: 9, teamID: "T0ACME", teamName: "acme", reboundFrom: "")))
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
    }

    /// A link refused while a cancelled flow still held the child arrives
    /// late as `link_busy`: it never fails the new start, and the new start's
    /// `browser` still shows (review m5).
    func testLateLinkBusyNeverFailsANewStart() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.linkBusy(flow: "f0"))
        XCTAssertEqual(rig.model.step, .starting(target))
        rig.emit(.browser(flow: "f1"))
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
        rig.emit(.linkBusy(flow: "f1"))
        XCTAssertEqual(rig.model.step, .browser(flow: "f1", target: target, since: clock))
        XCTAssertEqual(rig.sent, [startLine], "nothing cancelled: f1 is ours")
    }

    /// A start given up on (Cancel while starting) whose answer is lost to a
    /// `busy` is followed by a browser for that flow: it is cancelled, not
    /// left holding the child.
    func testBrowserOfAFlowWeGaveUpIsCancelled() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.model.cancel()
        rig.emit(.busy(flow: "f0")) // the cancelled start's answer
        rig.emit(.browser(flow: "f7"))
        XCTAssertEqual(rig.sent, [startLine, #"{"cmd":"cancel","flow":"f7"}"#])
        XCTAssertEqual(rig.model.step, .idle)
    }

    func testBusyAnswerFailsStart() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.busy(flow: "f0"))
        XCTAssertEqual(rig.model.sheet?.body,
                       "Could not connect: another Slack connection is still running. Nothing was saved.")
    }

    /// The child dies mid-flow: its flow is gone, the sheet says so and Start
    /// again goes to the restarted child.
    func testChildExitMidFlowFails() async {
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let now = clock
        let model = SlackConnectFlowModel(host: host) { now }
        host.ensureRunning()
        let first = await fake.session(number: 1)
        first.emit(#"{"event":"listening","port":18551}"#)
        await untilObserved { host.state == .listening }
        XCTAssertTrue(model.start(target))
        first.emit(#"{"event":"browser","flow":"f1"}"#)
        await untilObserved { if case .browser = model.step { true } else { false } }

        first.exit(code: 1)
        await untilObserved { if case .failed = model.step { true } else { false } }
        XCTAssertEqual(model.sheet?.body, "Could not connect: Watchtower's connect listener stopped. Nothing was saved.")

        let second = await fake.session(number: 2) // the one automatic restart (A10)
        model.startAgain()
        XCTAssertEqual(second.writtenLines, [startLine])
    }

    func testPortBusyDuringStartFails() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.portBusy(port: 18551))
        XCTAssertEqual(rig.model.sheet?.body, "Could not connect: port 18551 is busy. Nothing was saved.")
    }

    /// One flow at a time across the legacy sign-ins too (`SlackAuthFlowState`).
    func testStartWhileExternalBusyIsRefused() async {
        let rig = await makeRig()
        var busy = true
        rig.model.externalBusy = { busy }
        XCTAssertFalse(rig.model.canStart)
        XCTAssertFalse(rig.model.start(target))
        rig.emit(.link(flow: "f1", teamID: "T0ACME", clientID: "1111.2222"))
        rig.model.confirm()
        XCTAssertEqual(rig.sent, [], "no confirm while a legacy sign-in runs")
        busy = false
        rig.model.confirm()
        XCTAssertEqual(rig.sent, [#"{"cmd":"confirm","flow":"f1"}"#])
    }

    // MARK: - Re-login routing (A7, A14)

    private func doc(_ accounts: [SlackAccountsDocument.Account], builtin: Bool = false) -> SlackAccountsDocument {
        SlackAccountsDocument(builtinApp: builtin, accounts: accounts)
    }

    func testReloginRoutesWorkspaceAppToFlow() async {
        let rig = await makeRig()
        let accounts = doc([.init(id: 7, teamID: "T0ACME", clientID: "1111.2222", relogin: "connect")])
        let route = SlackReloginRoute.route(accountID: 7, in: accounts)
        XCTAssertEqual(route, .flow(SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222", accountID: 7)))
        XCTAssertTrue(rig.model.reconnect(route))
        XCTAssertEqual(rig.sent, [#"{"account_id":7,"client_id":"1111.2222","cmd":"start","team_id":"T0ACME"}"#],
                       "through the running child, never `slack login` on 18551")
        XCTAssertEqual(rig.model.connectSectionRequest, 0)
    }

    /// A legacy account #1 a pre-#915 Re-login moved to another team
    /// re-logs into the home team of its data (`home_team_id`, review m4);
    /// an older CLI without the field keeps `team_id`.
    func testReloginTargetsTheHomeTeam() throws {
        let json = #"{"builtin_app":false,"accounts":[{"id":1,"team_id":"T0OTHER","client_id":"1111.2222","#
            + #""shared_app":false,"relogin":"connect","home_team_id":"T0ACME"}]}"#
        let moved = try JSONDecoder().decode(SlackAccountsDocument.self, from: Data(json.utf8))
        XCTAssertEqual(SlackReloginRoute.route(accountID: 1, in: moved),
                       .flow(SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222", accountID: 1)))
        let older = doc([.init(id: 1, teamID: "T0OTHER", clientID: "1111.2222", relogin: "connect")])
        XCTAssertEqual(SlackReloginRoute.route(accountID: 1, in: older),
                       .flow(SlackConnectTarget(teamID: "T0OTHER", clientID: "1111.2222", accountID: 1)))
    }

    func testReloginConnectWithoutClientIDOpensConnectSection() async {
        let rig = await makeRig()
        let accounts = doc([.init(id: 1, teamID: "T0ACME", clientID: "", relogin: "connect")])
        let route = SlackReloginRoute.route(accountID: 1, in: accounts)
        XCTAssertEqual(route, .connectSection)
        XCTAssertTrue(rig.model.reconnect(route))
        XCTAssertEqual(rig.sent, [], "no start sent")
        XCTAssertEqual(rig.model.connectSectionRequest, 1, "the connect section is focused")
        XCTAssertEqual(rig.model.step, .idle)
    }

    func testReloginMoveOpensBannerPathNotFlow() async {
        let rig = await makeRig()
        let accounts = doc([.init(id: 2, teamID: "T0ACME", clientID: "9999.0000", sharedApp: true, relogin: "move")])
        let route = SlackReloginRoute.route(accountID: 2, in: accounts)
        XCTAssertEqual(route, .connectSection)
        XCTAssertTrue(rig.model.reconnect(route))
        XCTAssertEqual(rig.sent, [], "no start sent: the retired app never gets a PKCE flow")
        XCTAssertEqual(rig.model.connectSectionRequest, 1)
    }

    func testReloginBuiltinStaysWithTheCaller() async {
        let rig = await makeRig()
        let accounts = doc([.init(id: 3, teamID: "T0ACME", clientID: "5555.6666", relogin: "builtin")], builtin: true)
        XCTAssertEqual(SlackReloginRoute.route(accountID: 3, in: accounts), .builtin)
        XCTAssertFalse(rig.model.reconnect(.builtin))
        XCTAssertEqual(rig.sent, [])
        XCTAssertEqual(rig.model.connectSectionRequest, 0)
    }

    /// The legacy Workspace block (account #1) with no row yet.
    func testLegacyReconnectWithoutRowFollowsBuiltinApp() {
        XCTAssertEqual(SlackReloginRoute.route(accountID: 1, in: doc([], builtin: true)), .builtin)
        XCTAssertEqual(SlackReloginRoute.route(accountID: 1, in: doc([], builtin: false)), .connectSection)
        let noTeam = doc([.init(id: 1, teamID: "", clientID: "1.2", relogin: "connect")])
        XCTAssertEqual(SlackReloginRoute.route(accountID: 1, in: noTeam), .connectSection,
                       "a row without a team has nothing to re-bind")
        XCTAssertEqual(SlackReloginRoute.route(
            accountID: 1, in: doc([.init(id: 1, teamID: "T0ACME", clientID: "1.2", relogin: "later")])), .connectSection)
    }

    func testDecodesAccountsDocument() throws {
        let json = #"{"builtin_app":false,"accounts":[{"id":4,"team_id":"T0ACME","team_name":"acme","label":"","#
            + #""status":"ok","enabled":true,"client_id":"1111.2222","shared_app":false,"relogin":"connect"}]}"#
        let decoded = try JSONDecoder().decode(SlackAccountsDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, doc([.init(id: 4, teamID: "T0ACME", clientID: "1111.2222", relogin: "connect")]))
        XCTAssertEqual(try JSONDecoder().decode(SlackAccountsDocument.self, from: Data(#"{"builtin_app":true,"accounts":null}"#.utf8)),
                       doc([], builtin: true))
        XCTAssertEqual(SlackAccountsDocument.args, ["slack", "accounts", "--json"])
    }

    // MARK: - Fix round 1

    /// A link while a cancelled start still waits for its answer is not shown: cancelled too.
    func testLinkWhileCancelledStartAwaitsIsCancelled() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.model.cancel()
        rig.emit(.link(flow: "f7", teamID: "T0ACME", clientID: "1111.2222"))
        XCTAssertEqual(rig.model.step, .idle)
        XCTAssertEqual(rig.sent, [startLine, #"{"cmd":"cancel","flow":"f7"}"#])
    }

    /// A start the child began and then failed carries its flow id: it still answers the start.
    func testFailedWithFlowWhileStartingAnswersStart() async {
        let rig = await makeRig()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.failed(flow: "f1", reason: .other, message: "Watchtower could not start the connection."))
        XCTAssertEqual(rig.model.step, .failed(.other("Watchtower could not start the connection"), retry: target))

        // Cancelled before that answer: the answer clears the wait, nothing shows.
        rig.model.dismiss()
        XCTAssertTrue(rig.model.start(target))
        rig.model.cancel()
        XCTAssertFalse(rig.model.canStart)
        rig.emit(.failed(flow: "f2", reason: .other, message: "x"))
        XCTAssertEqual(rig.model.step, .idle)
        XCTAssertTrue(rig.model.canStart)
    }

    /// A cancelled flow's late answer never lands on the next flow, and any
    /// written account reloads the list even when its flow is not shown.
    func testCancelledFlowKeepsItsAnswerAcrossANewStart() async {
        let rig = await makeRig()
        var written: [Int64] = []
        rig.model.onConnected = { written.append($0.accountID) }
        inBrowser(rig)
        rig.model.cancel()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.failed(flow: "f1", reason: .cancelled, message: "This connection was cancelled in Watchtower."))
        XCTAssertEqual(rig.model.step, .starting(target), "f1's answer is not the new start's")
        rig.emit(.browser(flow: "f2"))
        rig.emit(.connected(SlackConnectedAccount(flow: "zz", accountID: 8, teamID: "T0ACME", teamName: "acme", reboundFrom: "")))
        XCTAssertEqual(rig.model.step, .browser(flow: "f2", target: target, since: clock))
        XCTAssertEqual(written, [8])
    }

    /// A Reconnect that opens the pane asks before the pane mounts: the pane
    /// takes the request once, on appear or on change.
    func testConnectSectionRequestIsTakenOnce() async {
        let rig = await makeRig()
        XCTAssertFalse(rig.model.takeConnectSectionRequest())
        rig.model.reconnect(.connectSection)
        XCTAssertTrue(rig.model.takeConnectSectionRequest())
        XCTAssertFalse(rig.model.takeConnectSectionRequest(), "a remounted pane does not unfold it again")
        rig.model.reconnect(.connectSection)
        XCTAssertTrue(rig.model.takeConnectSectionRequest())
    }

    // MARK: - Fix round 2

    /// A cancelled flow's late success while a newer start runs: the list
    /// reloads, the newer attempt keeps its sheet.
    func testLateSuccessOfCancelledFlowLeavesNewerStart() async {
        let rig = await makeRig()
        var written: [Int64] = []
        rig.model.onConnected = { written.append($0.accountID) }
        inBrowser(rig)
        rig.model.cancel()
        XCTAssertTrue(rig.model.start(target))
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 5, teamID: "T0ACME", teamName: "acme", reboundFrom: "")))
        XCTAssertEqual(rig.model.step, .starting(target))
        XCTAssertEqual(written, [5])
    }

    /// The setup's admin connect awaits its flow to the end, through the
    /// real flow model, and leaves no sheet behind.
    func testSetupConnectorAwaitsTheFlow() async {
        let rig = await makeRig()
        let connector = SlackSetupConnector(flow: rig.model)
        let run = Task { await connector.connectForSetup(teamID: "T0ACME", clientID: "1111.2222") }
        await untilObserved { rig.model.step == .starting(self.target) }
        XCTAssertEqual(rig.sent, [startLine], "skip-confirm, straight to Slack")
        rig.emit(.browser(flow: "f1"))
        rig.emit(.connected(SlackConnectedAccount(flow: "f1", accountID: 2, teamID: "T0ACME", teamName: "acme", reboundFrom: "")))
        let outcome = await run.value
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(rig.model.step, .idle)

        let failed = Task { await connector.connectForSetup(teamID: "T0ACME", clientID: "1111.2222") }
        await untilObserved { rig.model.step == .starting(self.target) }
        rig.emit(.browser(flow: "f2"))
        rig.emit(.failed(flow: "f2", reason: .denied, message: ""))
        let notConnected = await failed.value
        XCTAssertEqual(notConnected, .notConnected)
        XCTAssertEqual(rig.model.step, .idle)

        // A flow already running: nothing starts.
        rig.emit(.link(flow: "f3", teamID: "T0ACME", clientID: "1111.2222"))
        let refused = await connector.connectForSetup(teamID: "T0ACME", clientID: "1111.2222")
        XCTAssertEqual(refused, .notConnected)
    }

    /// A13: the onboarding sheet's own strings (the field and its buttons are
    /// the connect section's, pinned in `testConnectSectionStrings`).
    func testOnboardingStrings() {
        XCTAssertEqual(SlackConnectFlowModel.onboardingTitle, "Connect Slack")
        XCTAssertEqual(SlackConnectFlowModel.onboardingCaption, "Watchtower connects through your workspace's own "
            + "Slack app. Open Watchtower in Slack, go to its About tab and click the connect link, or paste the "
            + "link or code here.")
        XCTAssertEqual(SlackConnectFlowModel.onboardingLiveHint, "No app in your workspace? Chats can still read "
            + "Slack through Live in your Claude or ChatGPT account.")
        XCTAssertEqual(SlackConnectFlowModel.onboardingSkip, "Skip")
    }
}
