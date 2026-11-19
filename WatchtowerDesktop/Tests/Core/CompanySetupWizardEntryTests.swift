import Foundation
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// Task 22: the Slack setup-record rows open the wizard at their step (A19),
/// and the page's own strings.
@MainActor
final class CompanySetupWizardEntryTests: XCTestCase {
    private typealias Model = CompanySetupWizardModel
    private let acmeSetup = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","#
        + #""connected":true,"link_written":false,"install_requested":false,"stage":"link_missing"}]}"#

    private func make(_ cli: CompanyScriptedCLI) -> Model {
        Model(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard))
    }

    private func record(_ stage: String) -> SlackSetupRecord {
        SlackSetupRecord(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222", connected: true,
                         linkWritten: false, installRequested: false, stage: stage)
    }

    func testRecordRowsMapToTheirStep() {
        XCTAssertNil(Model.Entry(record: record("install")), "the admin connect stays on plan B's sheet")
        XCTAssertNil(Model.Entry(record: record("approval")), "Check again stays on plan B's sheet")
        XCTAssertEqual(Model.Entry(record: record("link_missing")), .publish(appID: "A0ACME"))
        XCTAssertNil(Model.Entry(record: record("pending_create")), "a lost create stays on plan B's sheet")
        XCTAssertNil(Model.Entry(record: record("done")))
    }

    /// Asked before the page opened, the entry lands once the draft is read:
    /// Slack ticked, its app referenced (the record owns it), Publish reached.
    func testAddLinkOpensPublishWithTheRecordsApp() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let model = make(cli)
        model.request(.publish(appID: "A0ACME"))
        XCTAssertEqual(model.current, .services, "nothing moves before the draft is read")
        await model.open()
        XCTAssertEqual(model.current, .publish)
        XCTAssertEqual(model.ticked, [.slack])
        XCTAssertEqual(model.draft.slack.appID, "A0ACME")
        XCTAssertTrue(model.slackAppReady)
        XCTAssertEqual(model.marks()[.vendor(.slack)], .done)
        XCTAssertTrue(model.reached.contains(.vendor(.slack)), "the rail can go back to every step before")
        await model.leave()
        let saved = cli.calls(["company", "draft", "save"]).last?.input ?? ""
        XCTAssertTrue(saved.contains(#""step":"publish""#), saved)
    }

    /// On an open page, Continue setup moves to the Slack step at once; a draft
    /// with its own app keeps it.
    func testContinueSetupKeepsTheDraftsOwnApp() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup.replacingOccurrences(of: "]}", with: #",{"team_id":"T0OWN","team_name":"own","#
            + #""app_id":"A0OWN","client_id":"3333.4444","connected":true,"link_written":false,"#
            + #""install_requested":false,"stage":"link_missing"}]}"#)
        cli.on(["company", "draft", "show"], [#"{"state":"ok","draft":{"company":"Acme","services":["google"],"#
            + #""step":"google","slack":{"app_id":"A0OWN"}},"bad_file":"","checked_vendors":[]}"#])
        let model = make(cli)
        await model.open()
        model.request(.slackStep(appID: "A0ACME"))
        XCTAssertEqual(model.current, .vendor(.slack))
        XCTAssertEqual(model.ticked, [.slack, .google])
        XCTAssertEqual(model.draft.slack.appID, "A0OWN", "another record never replaces the draft's app")

        // Add the link for another app than the draft's: never Publish with the wrong one.
        model.goTo(.services)
        model.request(.publish(appID: "A0ACME"))
        XCTAssertEqual(model.current, .vendor(.slack), "the Slack step shows which app the setup holds")
        XCTAssertEqual(model.draft.slack.appID, "A0OWN")
    }

    /// A draft that could not be read keeps the entry for the next open.
    func testEntryWaitsForAReadableDraft() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        cli.on(["company", "draft", "show"], [], exit: 1)
        let model = make(cli)
        model.request(.slackStep(appID: "A0ACME"))
        await model.open()
        XCTAssertEqual(model.load, .notOpened)
        XCTAssertEqual(model.storageProblem, Model.draftReadFailed)
        await model.open()
        XCTAssertEqual(model.current, .vendor(.slack))
    }

    /// Not a collaborator is the app's problem (the token form folds, Try
    /// again keeps the token); a bad token is the token's (the form shows).
    func testSlackProblemNamesTheApp() async {
        let cli = CompanyScriptedCLI()
        let model = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.createNew()
        model.slackToken = "xoxe.xoxp-1-sample-token"
        cli.on(["slack", "app", "create"], [#"{"result":"bad_token"}"#])
        await model.next()
        await untilObserved { model.slackProblem != nil }
        XCTAssertFalse(model.slackProblemNamesTheApp)

        model.back()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        cli.on(["slack", "app", "adopt"], [#"{"result":"not_collaborator","team_id":"T0ACME","team_name":"acme"}"#])
        await model.next()
        await untilObserved { model.slackProblem != nil }
        XCTAssertTrue(model.slackProblemNamesTheApp)
        XCTAssertFalse(model.slackToken.isEmpty, "Try again reuses the token")
    }

    /// While Publish runs, Back and the rail keep its step (its link and code land there).
    func testRunningPublishKeepsItsStep() async {
        let cli = CompanyScriptedCLI()
        let model = make(cli)
        await model.open()
        model.toggle(.linear)
        model.publishName = "Acme"
        await model.next() // Linear
        await model.skip()  // deny list
        await model.next() // Publish
        XCTAssertEqual(model.current, .publish)
        cli.hold(["company", "publish"])
        let run = Task { await model.next() }
        await cli.waitFor(["company", "publish"])
        model.back()
        model.goTo(.services)
        await model.discard()
        XCTAssertEqual(model.current, .publish)
        XCTAssertTrue(cli.calls(["company", "draft", "discard"]).isEmpty, "no discard under a running Publish")
        cli.release(["company", "publish"], [#"{"result":"no_slack","slug":"acme","link":"l","code":"c"}"#])
        await run.value
        XCTAssertTrue(model.isPublished)
    }

    /// Publish refused the token as another workspace's: the token field comes back for a new one.
    func testWrongWorkspaceTokenAsksForAnother() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        cli.on(["company", "draft", "show"], [#"{"state":"ok","draft":{"company":"Acme","services":["slack"],"#
            + #""step":"publish","slack":{"app_id":"A0ACME"}},"bad_file":"","checked_vendors":["slack"]}"#])
        let model = make(cli)
        await model.open()
        model.slackToken = "xoxe.xoxp-1-other-token"
        XCTAssertFalse(model.publishNeedsToken)
        cli.on(["company", "publish"], [#"{"result":"refused","reason":"wrong_workspace"}"#])
        await model.next()
        XCTAssertEqual(model.publishRefusal, Model.publishWrongWorkspace)
        XCTAssertTrue(model.publishNeedsToken, "the rejected token is not sent again")
    }

    /// An entry asked while the wizard's Slack run goes on waits for it, then
    /// checks the app the run set: another app → the Slack step, not Publish.
    func testEntryWaitsForTheSlackRun() async {
        let cli = CompanyScriptedCLI()
        let model = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.createNew()
        model.slackToken = "xoxe.xoxp-1-sample-token"
        cli.hold(["slack", "app", "create"])
        await model.next()
        await cli.waitFor(["slack", "app", "create"])
        await model.leave()
        model.request(.publish(appID: "A0OTHER"))
        XCTAssertEqual(model.current, .vendor(.slack), "nothing moves while the run goes on")
        cli.setups = acmeSetup
        cli.release(["slack", "app", "create"], [#"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
            + #""client_id":"1111.2222","link_written":false}"#])
        await untilObserved { model.reached.contains(.denyList) && model.current == .vendor(.slack) }
        XCTAssertEqual(model.draft.slack.appID, "A0ACME", "the run's app stays; the other row's never lands")
    }

    /// Ticks made while discovery looks are kept.
    func testTicksDuringDiscoveryWin() async {
        let cli = CompanyScriptedCLI()
        cli.hold(["company", "discover"])
        let model = make(cli)
        let open = Task { await model.open() }
        await cli.waitFor(["company", "discover"])
        model.toggle(.linear)
        cli.release(["company", "discover"], [#"{"candidates":[{"vendor":"slack","client_id":"1111.2222","#
            + #""label":"x","source":"account","source_label":"y"}]}"#])
        await open.value
        XCTAssertEqual(model.ticked, [.linear])
    }

    func testPageStrings() {
        XCTAssertEqual(Model.loadingLine, "Reading the setup's progress on this Mac…")
        XCTAssertEqual(Model.pastedJSON, "Pasted client JSON")
        XCTAssertEqual(Model.profileFailed, "Watchtower could not make the configuration profile. Try again.")
        XCTAssertEqual(Model.profileSaveFailed("disk full"), "The configuration profile could not be saved: disk full.")
        // Spike S1 has not settled the values: every Copy button copies nothing yet (and is disabled).
        for v in CompanyVendor.allCases {
            for line in CompanyVendorGuide.guideCopyButtons(v).keys {
                XCTAssertEqual(CompanyVendorGuide.guideCopyText(v, line: line), "")
            }
        }
    }
}
