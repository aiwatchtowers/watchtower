import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The admin's connect, scripted: each call takes the next outcome
/// (`.connected` when none is queued).
@MainActor
private final class FakeSetupConnector: SlackSetupConnectStarting {
    var outcomes: [SlackSetupConnectOutcome] = []
    private(set) var calls: [String] = []

    func connectForSetup(teamID: String, clientID: String) async -> SlackSetupConnectOutcome {
        calls.append("\(teamID):\(clientID)")
        return outcomes.isEmpty ? .connected : outcomes.removeFirst()
    }
}

@MainActor
final class SlackAppSetupModelTests: XCTestCase {
    private typealias Model = SlackAppSetupModel
    private let token = "xoxe.xoxp-1-sample-token"
    private let createArgs = ["slack", "app", "create", "--json"]
    private let noSetups = FakeCLILineStream.Reply(lines: [#"{"setups":[]}"#])

    private func step(_ name: String, _ state: String) -> String {
        #"{"step":"\#(name)","state":"\#(state)"}"#
    }

    private func result(
        _ kind: String,
        linkWritten: Bool = true,
        appID: String = "A0ACME",
        clientID: String = "1111.2222",
        extra: String = ""
    ) -> String {
        #"{"result":"\#(kind)","team_id":"T0ACME","team_name":"acme","app_id":"\#(appID)","client_id":"\#(clientID)","#
            + #""link_written":\#(linkWritten)\#(extra)}"#
    }

    private func reply(_ lines: String...) -> FakeCLILineStream.Reply {
        FakeCLILineStream.Reply(lines: lines)
    }

    private func make(
        _ replies: [FakeCLILineStream.Reply] = [], form: Model.Form = .create
    ) -> (Model, FakeCLILineStream, FakeSetupConnector) {
        let fake = FakeCLILineStream(replies: replies)
        let connector = FakeSetupConnector()
        let model = Model(streamer: fake, form: form)
        model.connector = connector
        return (model, fake, connector)
    }

    private func finished(_ model: Model) async {
        await untilObserved { if case .finished = model.phase { true } else { false } }
    }

    private func settled(_ model: Model) async {
        await untilObserved { !model.isRunning && !model.holdsToken }
    }

    private func labels(_ model: Model) -> [String] {
        model.actions.map(\.label)
    }

    private var adopt: Model.Form {
        .adopt(Model.Adopt(target: SlackSetupTarget(teamID: "T0ACME", teamName: "acme", clientID: "1111.2222")))
    }

    // MARK: - §3.2 the sheet's strings

    func testFormStrings() {
        let (model, _, _) = make()
        XCTAssertEqual(model.title, "Set up Watchtower for your company")
        XCTAssertEqual(model.intro, "Creates Watchtower's app in your Slack workspace from our manifest. Colleagues then "
            + "connect from the app's About page in Slack; nothing depends on this Mac afterwards.")
        XCTAssertEqual(Model.step1Title, "1. Generate a configuration token")
        XCTAssertEqual(Model.step1Help, "On Slack's app page, under Your App Configuration Tokens, press Generate Token "
            + "for your workspace and copy the access token.")
        XCTAssertEqual(Model.openTokenPage, "Open Slack's token page")
        XCTAssertEqual(Model.step2Title, "2. Paste it here")
        XCTAssertEqual(Model.tokenPlaceholder, "Configuration token")
        XCTAssertEqual(Model.tokenNote, "Used once for this setup and never stored.")
        XCTAssertTrue(model.showsTokenForm)
        XCTAssertTrue(model.showsDisclosure)
        XCTAssertNil(model.notice)
        XCTAssertEqual(labels(model), ["Cancel", "Create the app"])
        XCTAssertEqual(model.actions.filter(\.prominent).count, 1)
        XCTAssertFalse(model.isEnabled(.create, token: "  "), "Create is disabled while the field is empty")
        XCTAssertTrue(model.isEnabled(.create, token: token))
        XCTAssertEqual(Model.createSteps.map(\.label), [
            "Checking the token", "Creating the app", "Writing the connect link to its About page",
            "Connecting your Slack account"
        ])
        XCTAssertEqual(Model.progressCaption, "Keep this window open. If it closes, continue from Connections → Slack; "
            + "the app is never created twice.")
    }

    func testStepMarksFromScriptedCLI() async {
        let (model, fake, connector) = make()
        model.startCreate(token: token)
        XCTAssertTrue(model.showsProgress)
        XCTAssertEqual(labels(model), ["Close"])
        let child = await fake.session(number: 1)

        child.emit(step("check_token", "running"))
        await untilObserved { model.steps[0].mark == .running }
        XCTAssertEqual(model.steps.map(\.mark), [.running, .waiting, .waiting, .waiting])
        child.emit(step("check_token", "done"))
        child.emit(step("create_app", "running"))
        await untilObserved { model.steps[1].mark == .running }
        XCTAssertEqual(model.steps.map(\.mark), [.done, .running, .waiting, .waiting])
        child.emit(step("create_app", "done"))
        child.emit(step("write_link", "running"))
        child.emit(step("write_link", "done"))
        child.emit(result("ok"))
        child.exit()

        await finished(model)
        XCTAssertEqual(model.steps.map(\.mark), [.done, .done, .done, .done])
        XCTAssertEqual(connector.calls, ["T0ACME:1111.2222"], "the admin's connect is step 4")
        XCTAssertEqual(model.notice?.title, "Watchtower's app is ready in acme")
        XCTAssertEqual(model.notice?.body, "You are connected. Colleagues open Watchtower in Slack, go to About and "
            + "click the connect link.")
        XCTAssertEqual(labels(model), ["Copy connect code", "Done"])
        XCTAssertEqual(model.connectCode, "T0ACME:1111.2222")
        XCTAssertFalse(model.showsTokenForm)
    }

    func testTokenNeverInArgv() async {
        let (model, fake, _) = make([reply(result("link_failed", linkWritten: false)), reply(result("ok")), noSetups])
        model.startCreate(token: token)
        await settled(model)

        let calls = fake.invocations
        XCTAssertEqual(calls.map(\.args), [createArgs, ["slack", "app", "link", "--json", "--team", "T0ACME"],
                                           ["slack", "app", "status", "--json"]])
        for call in calls {
            XCTAssertFalse(call.args.joined(separator: " ").contains("xoxe"), "token in argv: \(call.args)")
        }
        XCTAssertEqual(calls[0].stdin, Data((token + "\n").utf8))
        XCTAssertEqual(calls[1].stdin, Data((token + "\n").utf8), "the link retry reuses the held token on stdin")
        XCTAssertNil(calls[2].stdin)
    }

    func testTokenDroppedAfterRun() async {
        let (model, fake, _) = make()
        model.startCreate(token: token)
        XCTAssertTrue(model.holdsToken)
        let child = await fake.session(number: 1)
        child.emit(result("bad_token"))
        child.exit()
        await settled(model)
        XCTAssertFalse(model.holdsToken)
    }

    func testCloseKeepsRunning() async {
        let (model, fake, connector) = make()
        model.present()
        XCTAssertTrue(model.isPresented)
        model.startCreate(token: token)
        let child = await fake.session(number: 1)
        model.close()
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(model.isRunning, "closing the sheet does not stop the run")

        child.emit(result("ok"))
        child.exit()
        await finished(model)
        XCTAssertEqual(connector.calls.count, 1)
        guard case .finished(.success) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertFalse(child.terminated)

        // Reopened while a run goes: the run shows, nothing restarts.
        let (busy, busyFake, _) = make()
        busy.startCreate(token: token)
        _ = await busyFake.session(number: 1)
        busy.close()
        busy.present()
        XCTAssertTrue(busy.isRunning)
        XCTAssertEqual(busyFake.invocations.count, 1)
    }

    // MARK: - Resume: the record, never a second create

    func testRecordOffersContinueNotCreate() async {
        let record = SlackSetupRecord(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222",
                                      connected: false, linkWritten: true, installRequested: false, stage: "install")
        let (model, fake, connector) = make([noSetups])
        await model.reloadRecords()
        let status = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","#
            + #""connected":false,"link_written":true,"install_requested":false,"stage":"install"}]}"#
        fake.enqueue(reply(status))
        await model.reloadRecords()
        XCTAssertEqual(model.records, [record])
        XCTAssertEqual(model.recordRows.map(\.text),
                       ["Setup is not finished: Watchtower's app exists in acme, but you have not connected yet."])
        XCTAssertEqual(model.recordRows.map(\.label), ["Continue setup"])

        fake.enqueue(noSetups)
        model.open(record)
        XCTAssertTrue(model.isPresented)
        await finished(model)
        XCTAssertEqual(connector.calls, ["T0ACME:1111.2222"])
        XCTAssertFalse(fake.invocations.contains { $0.args == createArgs }, "Continue setup never creates")
        guard case .finished(.success) = model.phase else { return XCTFail("\(model.phase)") }

        // A create that finds the record answers exists: the same path.
        let (again, againFake, againConnector) = make([reply(result("exists", linkWritten: true)), noSetups, noSetups])
        again.startCreate(token: token)
        await settled(again)
        XCTAssertEqual(againFake.invocations.filter { $0.args == createArgs }.count, 1)
        XCTAssertEqual(againConnector.calls, ["T0ACME:1111.2222"])
        guard case .finished(.success) = again.phase else { return XCTFail("\(again.phase)") }
    }

    func testExistsAlreadyConnectedSkipsTheConnect() async {
        let status = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","#
            + #""connected":true,"link_written":true,"install_requested":false,"stage":"done"}]}"#
        let (model, _, connector) = make([reply(result("exists")), reply(status), noSetups])
        model.startCreate(token: token)
        await settled(model)
        XCTAssertTrue(connector.calls.isEmpty)
        guard case .finished(.success) = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testLinkFailedOffersAddLink() async {
        // The link fails in the create and again on the retry after the connect.
        let (model, fake, connector) = make([reply(result("link_failed", linkWritten: false)),
                                             reply(result("bad_token")), noSetups])
        model.startCreate(token: token)
        await settled(model)
        XCTAssertEqual(connector.calls.count, 1)
        XCTAssertEqual(model.notice?.title, "Watchtower's app is ready in acme")
        XCTAssertEqual(model.notice?.body, "The app works, but its About page has no connect link yet: the token expired "
            + "before the link was written. Paste a fresh token to add it.")
        XCTAssertEqual(labels(model), ["Close", "Add the link to the app"])

        model.showAddLink()
        XCTAssertEqual(model.title, "Add the connect link to the app")
        XCTAssertEqual(model.intro, "Writes the connect link and code into the About page of Watchtower's app in acme. "
            + "Needs a fresh configuration token.")
        XCTAssertTrue(model.showsTokenForm)
        XCTAssertFalse(model.showsDisclosure)
        XCTAssertEqual(labels(model), ["Cancel", "Add the link"])

        let child = await startLink(model, fake)
        XCTAssertEqual(model.busyLine, "Writing the link…")
        XCTAssertFalse(model.showsProgress)
        XCTAssertFalse(model.isEnabled(.addLink, token: token), "no second run while busy")
        let opened = fake.sessions.count
        child.emit(result("ok"))
        child.exit()
        // The records say the owner is connected: the link sheet is done.
        let status = await fake.session(number: opened + 1)
        status.emit(#"{"setups":[\#(record(connected: true))]}"#)
        status.exit()
        await finished(model)
        XCTAssertEqual(model.notice?.body, "The connect link is on the app's About page.")
        XCTAssertEqual(labels(model), ["Done"])
        XCTAssertTrue(fake.invocations.contains { $0.args == ["slack", "app", "link", "--json", "--team", "T0ACME"] })
    }

    private func record(connected: Bool, stage: String = "done") -> String {
        #"{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","connected":\#(connected),"#
            + #""link_written":true,"install_requested":false,"stage":"\#(stage)"}"#
    }

    private func startLink(_ model: Model, _ fake: FakeCLILineStream) async -> FakeCLILineSession {
        let opened = fake.sessions.count
        model.startLink(team: "T0ACME", token: token)
        return await fake.session(number: opened + 1)
    }

    func testLinkRetryAfterConnectWritesTheLink() async {
        let (model, _, connector) = make([reply(result("link_failed", linkWritten: false)), reply(result("ok")), noSetups])
        model.startCreate(token: token)
        await settled(model)
        XCTAssertEqual(connector.calls.count, 1)
        guard case let .finished(.success(target)) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(target.linkWritten)
    }

    func testAddLinkBadTokenKeepsTheLinkSheet() async {
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222")
        let (model, _, _) = make([reply(result("bad_token")), noSetups], form: .addLink(target))
        model.startLink(team: "T0ACME", token: token)
        await settled(model)
        XCTAssertEqual(model.title, "Add the connect link to the app")
        XCTAssertEqual(model.notice?.body, Model.badTokenBody)
        XCTAssertEqual(labels(model), ["Cancel", "Try again"])
        model.tryAgain()
        XCTAssertEqual(labels(model), ["Cancel", "Add the link"])
    }

    // MARK: - Problems

    private func problem(_ line: String, form: Model.Form = .create) async -> Model {
        let (model, _, _) = make([reply(line), noSetups], form: form)
        if case .adopt = form {
            model.startAdopt(token: token, appID: nil)
        } else {
            model.startCreate(token: token)
        }
        await settled(model)
        return model
    }

    func testBadTokenState() async {
        let model = await problem(#"{"result":"bad_token","code":"invalid_auth"}"#)
        XCTAssertEqual(model.notice?.body, "That token did not work: it has expired or is not a configuration token. "
            + "Generate a new one and paste it.")
        XCTAssertNil(model.notice?.title)
        XCTAssertEqual(labels(model), ["Cancel", "Try again"])
        XCTAssertTrue(model.showsTokenForm)
        model.tryAgain()
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(labels(model), ["Cancel", "Create the app"])
    }

    func testNotAllowedState() async {
        let model = await problem(result("not_allowed", appID: "", clientID: "", extra: #","code":"restricted_action""#))
        XCTAssertEqual(model.notice?.body, "Your workspace does not let you create apps. Ask a workspace admin to run this setup.")
        XCTAssertEqual(labels(model), ["Cancel", "Copy a note for your admin", "Try again"])
        XCTAssertEqual(model.actions.filter(\.prominent).map(\.label), ["Try again"])
    }

    func testAdminNoteText() async {
        let model = await problem(result("not_allowed", appID: "", clientID: ""))
        XCTAssertFalse(model.adminNoteCopied)
        XCTAssertEqual(model.copyAdminNote(), "Please set up Watchtower for acme in Slack: "
            + "https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/concepts/sources-and-accounts.md")
        XCTAssertTrue(model.adminNoteCopied)
        XCTAssertEqual(Model.adminNoteCopiedLine, "Copied. Send it to a workspace admin.")
        XCTAssertEqual(Model.adminNote(workspace: ""), "Please set up Watchtower for our Slack workspace in Slack: "
            + Model.guideURL.absoluteString)
        model.tryAgain()
        XCTAssertFalse(model.adminNoteCopied)
    }

    func testNetworkState() async {
        let model = await problem(#"{"result":"network","error":"dial tcp: i/o timeout"}"#)
        XCTAssertEqual(model.notice?.body, "Could not reach Slack: dial tcp: i/o timeout. Nothing was created.")
        XCTAssertEqual(labels(model), ["Cancel", "Try again"])
    }

    func testRefusedState() async {
        let model = await problem(#"{"result":"refused","code":"invalid_manifest"}"#)
        XCTAssertEqual(model.notice?.body, "Slack refused the app: invalid_manifest. Nothing was created.")
        let adopted = await problem(#"{"result":"refused","code":"ratelimited"}"#, form: adopt)
        XCTAssertEqual(adopted.notice?.body, "Slack refused the change: ratelimited. Nothing was changed.")
    }

    func testBusyShowsAlreadyRunning() async {
        let model = await problem(#"{"result":"busy"}"#)
        XCTAssertEqual(model.notice?.body, "Another setup is already running on this Mac. Try again once it has finished.")

        // A second start while a run goes sends nothing.
        let (running, fake, _) = make()
        running.startCreate(token: token)
        _ = await fake.session(number: 1)
        running.startCreate(token: token)
        running.startAdopt(token: token, appID: nil)
        XCTAssertEqual(fake.invocations.count, 1)
    }

    func testOtherResultsSayWhatHappened() async {
        let storage = await problem(#"{"result":"storage"}"#)
        XCTAssertEqual(storage.notice?.body, Model.storageBody)
        let noApp = await problem(result("no_app"), form: adopt)
        XCTAssertEqual(noApp.notice?.body, "Watchtower's app is not connected in acme any more, so there is nothing to "
            + "update. Create the app instead.")
        noApp.tryAgain()
        XCTAssertEqual(noApp.form, .create, "nothing to adopt: back to creating")
        let unknown = await problem(#"{"result":"brand_new"}"#)
        XCTAssertEqual(unknown.notice?.body, "The setup stopped before it finished: brand_new. Connections → Slack shows "
            + "where it got to; the app is never created twice.")
    }

    func testCLIExitsMidway() async {
        let (model, fake, connector) = make()
        model.startCreate(token: token)
        let child = await fake.session(number: 1)
        child.emit(step("check_token", "done"))
        child.emit(step("create_app", "running"))
        child.exit(code: 1)
        await settled(model)
        XCTAssertEqual(model.steps.map(\.mark), [.done, .failed, .waiting, .waiting])
        XCTAssertEqual(model.notice?.body, "The setup stopped before it finished: watchtower exited with error: exit 1. "
            + "Connections → Slack shows where it got to; the app is never created twice.")
        XCTAssertTrue(connector.calls.isEmpty)
        XCTAssertFalse(model.holdsToken)
    }

    func testNoCLIStops() async {
        let model = Model(streamer: nil)
        model.startCreate(token: token)
        await settled(model)
        guard case .finished(.problem(.stopped)) = model.phase else { return XCTFail("\(model.phase)") }
    }

    // MARK: - The admin's connect

    func testNoConnectFlowLeavesSetupUnfinished() async {
        let fake = FakeCLILineStream(replies: [reply(result("ok")), noSetups])
        let model = Model(streamer: fake)
        model.startCreate(token: token)
        await settled(model)
        XCTAssertEqual(model.notice?.body, "Setup is not finished: Watchtower's app exists in acme, but you have not connected yet.")
        XCTAssertEqual(labels(model), ["Close", "Continue setup"])
        XCTAssertEqual(model.steps.last?.mark, .failed)
    }

    func testApprovalThenCheckAgain() async {
        let (model, _, connector) = make([reply(result("ok")), noSetups, noSetups])
        connector.outcomes = [.approvalRequested]
        model.startCreate(token: token)
        await settled(model)
        XCTAssertEqual(model.notice?.body, "Waiting for your admin's approval. Slack sent them a request to install "
            + "Watchtower. Check again once they approve; this window can close.")
        XCTAssertEqual(labels(model), ["Close", "Check again"])

        model.checkAgain()
        await finished(model)
        XCTAssertEqual(connector.calls.count, 2)
        guard case .finished(.success) = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testApprovalRowOnlyWhenRecordSaysSo() async {
        func record(_ stage: String, requested: Bool) -> String {
            #"{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","connected":false,"#
                + #""link_written":true,"install_requested":\#(requested),"stage":"\#(stage)"}"#
        }
        let (model, fake, _) = make([reply(#"{"setups":[\#(record("install", requested: false))]}"#)])
        await model.reloadRecords()
        XCTAssertEqual(model.recordRows.map(\.label), ["Continue setup"])
        XCTAssertEqual(model.recordRows.map(\.waiting), [false])

        fake.enqueue(reply(#"{"setups":[\#(record("approval", requested: true))]}"#))
        await model.reloadRecords()
        XCTAssertEqual(model.recordRows.map(\.text), ["Waiting for your admin's approval in acme. Check again once they approve."])
        XCTAssertEqual(model.recordRows.map(\.label), ["Check again"])
        XCTAssertEqual(model.recordRows.map(\.waiting), [true])
    }

    func testRecordRowsPerStage() async {
        func record(_ stage: String, name: String = "acme") -> String {
            #"{"team_id":"T0ACME","team_name":"\#(name)","app_id":"A0ACME","client_id":"1111.2222","connected":true,"#
                + #""link_written":false,"install_requested":false,"stage":"\#(stage)"}"#
        }
        let (model, fake, _) = make([reply(#"{"setups":[\#(record("link_missing")),\#(record("done"))]}"#)])
        await model.reloadRecords()
        XCTAssertEqual(model.recordRows.map(\.text), ["The app's About page has no connect link yet, so colleagues cannot connect."])
        XCTAssertEqual(model.recordRows.map(\.label), ["Add the link to the app"])
        model.open(model.records[0])
        XCTAssertEqual(model.title, "Add the connect link to the app")

        // A failed read keeps the last rows; a record without a name shows its id.
        fake.enqueue(FakeCLILineStream.Reply(lines: [], exitCode: 1, stderr: "database is locked"))
        await model.reloadRecords()
        XCTAssertEqual(model.recordRows.count, 1)
        fake.enqueue(reply(#"{"setups":[\#(record("pending_create", name: ""))]}"#))
        await model.reloadRecords()
        XCTAssertEqual(model.recordRows.map(\.text), ["Setup is not finished: Slack did not confirm Watchtower's app in "
            + "T0ACME. Check api.slack.com/apps before going on."])
        fake.enqueue(reply(#"{"setups":null}"#))
        await model.reloadRecords()
        XCTAssertTrue(model.recordRows.isEmpty)
    }

    // MARK: - Adopt (ask #1425)

    func testExistingAppOffersAdoptNotCreate() async {
        let created = reply(step("check_token", "running"), step("check_token", "done"), result("existing_app", appID: ""))
        let (model, fake, connector) = make([created, noSetups])
        model.startCreate(token: token)
        await settled(model)
        XCTAssertEqual(fake.invocations.filter { $0.args == createArgs }.count, 1)
        XCTAssertTrue(connector.calls.isEmpty)
        XCTAssertEqual(model.notice?.title, "Watchtower's app already exists in acme")
        XCTAssertEqual(model.notice?.body, "Update it to the current version: Watchtower adds the connect link to its "
            + "About page and the sign-in settings it needs. Nothing changes for colleagues already connected.")
        XCTAssertEqual(labels(model), ["Cancel", "Update the app"])
        XCTAssertTrue(model.showsTokenForm)
        XCTAssertFalse(model.showsAppIDField)
    }

    func testAdoptNeedsAppID() async {
        let (model, fake, _) = make([reply(result("need_app_id", appID: "", extra: #","code":"app_id_missing""#)), noSetups],
                                    form: adopt)
        model.startAdopt(token: token, appID: nil)
        await settled(model)
        XCTAssertEqual(fake.invocations[0].args, ["slack", "app", "adopt", "--json", "--team", "T0ACME"])
        XCTAssertTrue(model.showsAppIDField)
        XCTAssertEqual(Model.appIDLabel, "App ID")
        XCTAssertEqual(Model.appIDHelp, "Find it on the app's Basic Information page at api.slack.com/apps.")
        XCTAssertNil(model.appIDProblemLine)
        XCTAssertFalse(model.isEnabled(.updateApp, token: token, appID: ""))
        XCTAssertTrue(model.isEnabled(.updateApp, token: token, appID: "A0ACME"))

        // A wrong shape is named.
        fake.enqueue(reply(result("need_app_id", appID: "", extra: #","code":"app_id_format""#)))
        fake.enqueue(noSetups)
        model.startAdopt(token: token, appID: "nope")
        await settled(model)
        XCTAssertEqual(model.appIDProblemLine, "That is not an App ID: it starts with A.")

        // An App ID from the field is confirmed by its name first.
        fake.enqueue(reply(step("check_token", "done"), step("read_app", "done"),
                           result("confirm_app", extra: #","app_name":"Watchtower""#)))
        fake.enqueue(noSetups)
        model.startAdopt(token: token, appID: " A0ACME ")
        await settled(model)
        XCTAssertEqual(fake.invocations.dropLast().last?.args, ["slack", "app", "adopt", "--json", "--team", "T0ACME", "--app-id", "A0ACME"])
        XCTAssertEqual(model.notice?.body, "App A0ACME is called “Watchtower”. Update it only if it is your workspace's "
            + "Watchtower app.")
        XCTAssertNil(model.appIDProblemLine)

        fake.enqueue(reply(result("ok")))
        fake.enqueue(noSetups)
        model.startAdopt(token: token, appID: "A0ACME")
        await settled(model)
        XCTAssertEqual(fake.invocations.dropLast().last?.args,
                       ["slack", "app", "adopt", "--json", "--team", "T0ACME", "--app-id", "A0ACME", "--confirm-app-id", "A0ACME"])
        guard case .finished(.success) = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testAdoptAppNotFound() async {
        let model = await problem(result("app_not_found", extra: #","code":"app_not_found""#), form: adopt)
        XCTAssertTrue(model.showsAppIDField)
        XCTAssertEqual(model.appIDProblemLine, "Slack has no app with that App ID in this workspace.")
    }

    func testNotCollaboratorState() async {
        let model = await problem(result("not_collaborator", extra: #","code":"no_permission""#), form: adopt)
        XCTAssertEqual(model.notice?.title, "Watchtower's app already exists in acme")
        XCTAssertEqual(model.notice?.body, "Your token cannot change this app. Ask one of its collaborators (listed on "
            + "its Collaborators page) to run this setup.")
        XCTAssertEqual(labels(model), ["Cancel", "Copy a note for your admin", "Try again"])
        XCTAssertTrue(model.copyAdminNote().hasPrefix("Please set up Watchtower for acme in Slack: "))
    }

    func testAdoptSuccess() async {
        let adopted = reply(step("check_token", "done"), step("update_app", "running"), step("update_app", "done"), result("ok"))
        let (model, fake, connector) = make([adopted, noSetups], form: adopt)
        model.startAdopt(token: token, appID: nil)
        XCTAssertEqual(model.steps.map(\.label), ["Checking the token", "Updating the app"])
        await settled(model)
        XCTAssertEqual(model.steps.map(\.mark), [.done, .done])
        XCTAssertTrue(connector.calls.isEmpty, "the adopter is already connected")
        XCTAssertEqual(model.notice?.title, "Watchtower's app is ready in acme")
        XCTAssertEqual(labels(model), ["Copy connect code", "Done"])
        XCTAssertEqual(fake.invocations[0].stdin, Data((token + "\n").utf8))
    }

    // MARK: - A create whose answer was lost

    func testPendingCreateLeftOver() async {
        let (model, fake, _) = make([reply(result("pending_create", appID: "", clientID: "")), noSetups])
        model.startCreate(token: token)
        await settled(model)
        XCTAssertTrue(model.showsPendingFields)
        XCTAssertFalse(model.showsTokenForm)
        XCTAssertEqual(model.notice?.body, "Slack did not answer when Watchtower asked it to create the app in acme, so "
            + "the app may exist. Look for “Watchtower” on api.slack.com/apps. If it is there, enter its App ID and "
            + "Client ID from its Basic Information page, then paste a fresh configuration token to add the connect link; "
            + "if not, start again.")
        XCTAssertEqual(labels(model), ["Cancel", "Start again", "Use this app"])
        XCTAssertFalse(model.isEnabled(.attachPending, token: "", appID: "A0ACME", clientID: ""))

        fake.enqueue(reply(#"{"result":"bad_ids","code":"client_id_format","team_id":"T0ACME"}"#))
        fake.enqueue(noSetups)
        model.attachPending(appID: "A0ACME", clientID: "x")
        await settled(model)
        XCTAssertEqual(model.notice?.body, "That is not a Client ID: two numbers joined by a dot.")
        model.tryAgain()

        fake.enqueue(reply(result("ok", linkWritten: false)))
        fake.enqueue(noSetups)
        model.attachPending(appID: "A0ACME", clientID: "1111.2222")
        await settled(model)
        XCTAssertEqual(fake.invocations.dropLast().last?.args, ["slack", "app", "pending", "--json", "--team", "T0ACME",
                                                                "--attach", "--app-id", "A0ACME", "--client-id", "1111.2222"])
        XCTAssertEqual(model.form, .addLink(SlackSetupTarget(teamID: "T0ACME", teamName: "acme", appID: "A0ACME",
                                                             clientID: "1111.2222")))
    }

    func testPendingClearStartsOver() async {
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "acme")
        let (model, fake, _) = make([reply(#"{"result":"ok","team_id":"T0ACME"}"#), noSetups], form: .pending(target))
        model.clearPending()
        XCTAssertTrue(fake.invocations.isEmpty, "the first Start again only asks to check Slack first")
        XCTAssertEqual(model.notice?.body, "Watchtower may have created the app already. Check Slack's app page first: "
            + "if “Watchtower” is there, enter its ids and use it. Start again only if it is not there, or the workspace "
            + "gets a second Watchtower app.")
        XCTAssertEqual(labels(model), ["Cancel", "Nothing there: start again", "Use this app"])
        var fields = Model.Fields()
        _ = model.perform(.confirmClear, fields: &fields)
        await untilObserved { model.form == .create }
        XCTAssertEqual(fake.invocations[0].args, ["slack", "app", "pending", "--json", "--team", "T0ACME", "--clear"])
        XCTAssertNil(fake.invocations[0].stdin)
        XCTAssertEqual(model.phase, .editing)
    }

    func testRelaunchShowsTheUnfinishedSetup() async {
        // A fresh model (the app relaunched mid-setup) reads the record.
        let status = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"","client_id":"","connected":false,"#
            + #""link_written":false,"install_requested":false,"stage":"pending_create"}]}"#
        let (model, _, _) = make([reply(status)])
        await model.reloadRecords()
        XCTAssertEqual(model.recordRows.map(\.label), ["Continue setup"])
        model.open(model.records[0])
        XCTAssertTrue(model.showsPendingFields)
    }
    // MARK: - Fix round 1

    func testAdoptPassesTheShownTeamAndRefusesAnother() async {
        let other = #"{"result":"wrong_team","team_id":"T0OTHER","team_name":"other"}"#
        let model = await problem(other, form: adopt)
        XCTAssertEqual(model.notice?.body, "That token is for other, not this setup's workspace. Generate one in the right "
            + "workspace.")
        XCTAssertEqual(labels(model), ["Cancel", "Try again"])
    }

    func testSubmitClearsTheTokenField() async {
        let (model, fake, _) = make()
        var fields = Model.Fields(token: token)
        XCTAssertNil(model.perform(.create, fields: &fields))
        XCTAssertEqual(fields.token, "", "the field is emptied; the token lives in the model for the run")
        XCTAssertTrue(model.holdsToken)
        let child = await fake.session(number: 1)
        XCTAssertEqual(fake.invocations[0].stdin, Data((token + "\n").utf8))
        child.emit(#"{"result":"bad_token"}"#)
        child.exit()
        await finished(model)

        // A disabled action changes nothing, the field included.
        var empty = Model.Fields(token: "")
        XCTAssertNil(model.perform(.tryAgain, fields: &empty))
        var kept = Model.Fields(token: token)
        let (busy, busyFake, _) = make()
        busy.startCreate(token: token)
        _ = await busyFake.session(number: 1)
        XCTAssertNil(busy.perform(.create, fields: &kept))
        XCTAssertEqual(kept.token, token)
        XCTAssertEqual(busyFake.invocations.count, 1)
    }

    func testCopyCodeOnlyWithACode() async {
        let success = Model(streamer: nil, phase: .finished(.success(SlackSetupTarget(teamID: "T0ACME", teamName: "acme"))))
        XCTAssertNil(success.connectCode)
        XCTAssertFalse(success.isEnabled(.copyCode, token: ""))
        let code = SlackSetupTarget(teamID: "T0ACME", teamName: "acme", clientID: "1111.2222")
        let full = Model(streamer: nil, phase: .finished(.success(code)))
        var fields = Model.Fields()
        XCTAssertEqual(full.perform(.copyCode, fields: &fields), "T0ACME:1111.2222")
    }

    func testAccountsChangedReloadsTheRecords() async {
        let (model, fake, _) = make([reply(#"{"setups":[\#(record(connected: false, stage: "install"))]}"#)])
        model.accountsChanged()
        await untilObserved { !model.records.isEmpty }
        XCTAssertEqual(fake.invocations.map(\.args), [["slack", "app", "status", "--json"]])
    }

    func testConnectorIsHeldStrongly() async {
        let fake = FakeCLILineStream(replies: [reply(result("ok")), noSetups])
        let model = Model(streamer: fake)
        var calls = 0
        do {
            final class Counting: SlackSetupConnectStarting {
                let onCall: () -> Void
                init(_ onCall: @escaping () -> Void) { self.onCall = onCall }
                func connectForSetup(teamID: String, clientID: String) async -> SlackSetupConnectOutcome {
                    onCall()
                    return .connected
                }
            }
            model.connector = Counting { calls += 1 }
        }
        model.startCreate(token: token)
        await settled(model)
        XCTAssertEqual(calls, 1)
    }

    func testCLIPathResolvedPerRun() async {
        // No CLI at the first run; installed before the second.
        var made = 0
        let fake = FakeCLILineStream(replies: [noSetups, reply(#"{"result":"busy"}"#), noSetups])
        let model = Model {
            made += 1
            return made == 1 ? nil : fake
        }
        XCTAssertEqual(made, 0, "nothing resolved before a run")
        model.startCreate(token: token)
        await settled(model)
        guard case .finished(.problem(.stopped)) = model.phase else { return XCTFail("\(model.phase)") }
        model.tryAgain()
        model.startCreate(token: token)
        await settled(model)
        guard case .finished(.problem(.busy)) = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testClearPendingAnsweredNoPendingSaysSo() async {
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "acme")
        let (model, _, _) = make([reply(#"{"result":"no_pending","team_id":"T0ACME"}"#), noSetups], form: .pending(target))
        model.clearPending()
        model.clearPending()
        await finished(model)
        XCTAssertEqual(model.notice?.body, "The setup for acme no longer waits for Slack's answer. Connections → Slack "
            + "shows where it stands.")
        XCTAssertEqual(labels(model), ["Done"])

        let (attach, _, _) = make([reply(#"{"result":"storage","team_id":"T0ACME"}"#), noSetups], form: .pending(target))
        attach.attachPending(appID: "A0ACME", clientID: "1111.2222")
        await finished(attach)
        XCTAssertEqual(attach.notice?.body, "Watchtower could not save this on this Mac. Nothing changed on Slack's side; "
            + "try again.")
    }

    func testAttachedAppLinkThenConnects() async {
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222")
        let notConnected = reply(#"{"setups":[\#(record(connected: false, stage: "install"))]}"#)
        let (model, _, connector) = make([reply(result("ok")), notConnected, noSetups], form: .addLink(target))
        model.startLink(team: "T0ACME", token: token)
        await settled(model)
        XCTAssertEqual(connector.calls, ["T0ACME:1111.2222"], "a link on an attached app goes on to the connect")
        guard case let .finished(.success(done)) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(done.linkWritten)
        XCTAssertEqual(model.steps.map(\.mark), [.done, .done, .done, .done])
    }

    func testNotCollaboratorFromLinkHasNoAdoptTitle() async {
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222")
        let (model, _, _) = make([reply(result("not_collaborator")), noSetups], form: .addLink(target))
        model.startLink(team: "T0ACME", token: token)
        await settled(model)
        XCTAssertNil(model.notice?.title)
        XCTAssertEqual(model.notice?.body, Model.notCollaboratorBody)
    }

    // MARK: - Spec review round

    func testNotAllowedShowsTheAdminNote() async {
        let model = await problem(result("not_allowed", appID: "", clientID: ""))
        XCTAssertEqual(model.adminNotePreview, "Please set up Watchtower for acme in Slack: " + Model.guideURL.absoluteString)
        model.tryAgain()
        XCTAssertNil(model.adminNotePreview)
        let bad = await problem(#"{"result":"bad_token"}"#)
        XCTAssertNil(bad.adminNotePreview)
    }

    func testStorageSaysHowToGoOn() async {
        let model = await problem(#"{"result":"storage"}"#)
        XCTAssertEqual(model.notice?.body, "Watchtower could not save the setup on this Mac, so it stopped. If Connections → "
            + "Slack shows the setup, press Continue setup there; otherwise try again. The app is never created twice.")
    }

    func testLinkWithUnreadableStatusGoesOnToTheConnect() async {
        let target = SlackSetupTarget(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222")
        let failedRead = FakeCLILineStream.Reply(lines: [], exitCode: 1, stderr: "database is locked")
        let (model, _, connector) = make([reply(result("ok")), failedRead, noSetups], form: .addLink(target))
        model.startLink(team: "T0ACME", token: token)
        await settled(model)
        XCTAssertEqual(connector.calls, ["T0ACME:1111.2222"], "an unconfirmed status never ends at Done")
        guard case .finished(.success) = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testOverlappingReadsKeepTheNewest() async {
        let (model, fake, _) = make()
        async let first = model.reloadRecords()
        let older = await fake.session(number: 1)
        async let second = model.reloadRecords()
        let newer = await fake.session(number: 2)
        newer.emit(#"{"setups":[\#(record(connected: false, stage: "install"))]}"#)
        newer.exit()
        let newerRead = await second
        XCTAssertTrue(newerRead)
        XCTAssertEqual(model.records.count, 1)
        older.emit(#"{"setups":[]}"#)
        older.exit()
        let olderRead = await first
        XCTAssertTrue(olderRead)
        XCTAssertEqual(model.records.count, 1, "the superseded read's answer is dropped")
    }
}
