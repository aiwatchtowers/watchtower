import Foundation
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

@MainActor
final class CompanySetupWizardModelTests: XCTestCase {
    private typealias Model = CompanySetupWizardModel
    private let token = "xoxe.xoxp-1-sample-token"
    private let started = ISO8601DateFormatter().date(from: "2026-11-17T09:00:00Z") ?? Date()
    private let acmeSetup = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","#
        + #""connected":false,"link_written":false,"install_requested":false,"stage":"link_missing"}]}"#
    private let atlassianOK = #"{"result":"ok","slug":"acme","account_id":7,"email":"alice@example.com","#
        + #""site":"https://acme.atlassian.net","checked":true,"confluence":true}"#
    private let googleOK = #"{"result":"ok","slug":"acme","account_id":3,"email":"alice@example.com","#
        + #""domain":"example.com","checked":true}"#

    private func make(_ cli: CompanyScriptedCLI = CompanyScriptedCLI()) -> (Model, CompanyScriptedCLI) {
        let slack = SlackAppSetupModel(streamer: cli, mode: .wizard)
        let started = started
        return (Model(streamer: cli, slack: slack) { started }, cli)
    }

    private func draftShow(_ draft: String, checked: [String] = []) -> String {
        let list = checked.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"state":"ok","draft":"# + draft + #","bad_file":"","checked_vendors":[\#(list)]}"#
    }

    /// A model opened on a stored draft.
    private func resume(
        _ draft: String, checked: [String] = [], cli: CompanyScriptedCLI = CompanyScriptedCLI()
    ) async -> (Model, CompanyScriptedCLI) {
        cli.on(["company", "draft", "show"], [draftShow(draft, checked: checked)])
        let (model, cli) = make(cli)
        await model.open()
        return (model, cli)
    }

    private func savedDrafts(_ cli: CompanyScriptedCLI) -> [[String: Any]] {
        cli.calls(["company", "draft", "save"]).compactMap {
            $0.stdin.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private let atlassianDraft = #"{"company":"Acme","services":["atlassian"],"step":"atlassian","#
        + #""started_at":"2026-11-17T09:00:00Z","slack":{},"atlassian":{"client_id":"9f3a8d0e4b7c21","#
        + #""client_secret":"sample-secret","site":"https://acme.atlassian.net","confluence":true}}"#

    // MARK: - Services step

    func testServicesNeedOneTicked() async {
        let (model, _) = make()
        await model.open()
        XCTAssertEqual(model.current, .services)
        XCTAssertFalse(model.primary.enabled)
        model.toggle(.google)
        XCTAssertTrue(model.primary.enabled)
        XCTAssertEqual(model.primary.title, "Continue")
        model.toggle(.google)
        XCTAssertFalse(model.primary.enabled)
    }

    func testDiscoveredServicesArePreTicked() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"atlassian","client_id":"9f3a8d0e4b7c21","#
            + #""label":"Acme app","source":"stored","source_label":"Acme's saved company setup"}]}"#])
        let (model, _) = make(cli)
        await model.open()
        XCTAssertEqual(model.ticked, [.atlassian])
        let row = model.servicesRows.first { $0.vendor == .atlassian }
        XCTAssertEqual(row?.detail, "Issues and pages through your company's Atlassian app · Found on this Mac")
        XCTAssertEqual(row?.ticked, true)
        XCTAssertEqual(model.servicesRows.first { $0.vendor == .slack }?.detail, "Messages, digests and the Inbox")
        // The rail already lists the ticked service.
        XCTAssertEqual(model.steps, [.services, .vendor(.atlassian), .denyList, .publish])
    }

    func testRailListsOnlyTickedServices() async {
        let (model, _) = make()
        await model.open()
        XCTAssertEqual(model.steps, [.services, .denyList, .publish])
        model.toggle(.microsoft)
        model.toggle(.slack)
        model.toggle(.google)
        XCTAssertEqual(model.steps, [.services, .vendor(.slack), .vendor(.google), .vendor(.microsoft), .denyList, .publish])
        XCTAssertEqual(model.steps.map(Model.railName), ["Services", "Slack", "Google", "Microsoft 365", "Link deny list", "Publish"])
        await model.next()
        XCTAssertEqual(model.railNarrowLine, "Step 2 of 6 · Slack")
    }

    func testUntickFilledStepAsksFirst() async {
        let (model, cli) = await resume(atlassianDraft)
        let warning = model.toggle(.atlassian)
        XCTAssertEqual(warning?.title, "Stop setting up Atlassian?")
        XCTAssertEqual(warning?.body, "What you entered for it (client id and secret) is dropped from the draft. An app you "
            + "created stays in Atlassian.")
        XCTAssertEqual(warning?.drop, "Drop Atlassian")
        XCTAssertEqual(warning?.keep, "Keep")
        XCTAssertEqual(model.ticked, [.atlassian], "nothing changes before the answer")
        model.keepService()
        XCTAssertNil(model.dropWarning)
        XCTAssertEqual(model.ticked, [.atlassian])
        model.toggle(.atlassian)
        model.confirmDrop(.atlassian)
        XCTAssertEqual(model.ticked, [])
        XCTAssertNil(model.draft.atlassian)
        await model.leave()
        let saved = savedDrafts(cli).last
        XCTAssertNil(saved?["atlassian"], "the entries leave the draft")
        XCTAssertEqual(saved?["services"] as? [String], [])
    }

    func testUntickEmptyStepDropsSilently() async {
        let (model, _) = make()
        await model.open()
        model.toggle(.linear)
        XCTAssertNil(model.toggle(.linear))
        XCTAssertEqual(model.ticked, [])
    }

    // MARK: - Leaving and resuming

    func testLeavingPageKeepsDraftAndResumesAtStep() async {
        let (model, cli) = make()
        await model.open()
        model.toggle(.linear)
        await model.next()
        XCTAssertEqual(model.current, .vendor(.linear))
        model.createNew()
        model.setField(.linear, .clientID, "lin_client_1")
        XCTAssertNil(model.resumeLine)
        await model.leave()
        let saved = savedDrafts(cli).last
        XCTAssertEqual(saved?["step"] as? String, "linear")
        XCTAssertEqual((saved?["linear"] as? [String: String])?["client_id"], "lin_client_1")
        XCTAssertEqual(model.resumeLine, "Continuing the setup you started on Nov 17.")

        // A new run (the app restarted) opens at the draft's step.
        let draft = #"{"company":"","services":["linear"],"step":"linear","started_at":"2026-11-17T09:00:00Z","#
            + #""slack":{},"linear":{"client_id":"lin_client_1"}}"#
        let (again, _) = await resume(draft)
        XCTAssertEqual(again.current, .vendor(.linear))
        XCTAssertEqual(again.phase(.linear), .create, "typed entries open the fields")
        XCTAssertEqual(again.draft.linear?.clientID, "lin_client_1")
        XCTAssertEqual(again.resumeLine, "Continuing the setup you started on Nov 17.")
        XCTAssertEqual(again.marks()[.services], .done)
    }

    func testCheckInFlightLandsInDraft() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.hold(["company", "check", "atlassian"])
        let check = Task { await model.check(.atlassian) }
        await cli.waitFor(["company", "check", "atlassian"])
        XCTAssertEqual(model.checks[.atlassian], .running)
        await model.leave()
        cli.release(["company", "check", "atlassian"], [atlassianOK])
        await check.value
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertEqual(model.draft.slug, "acme")
        // The result is saved: Go's mark stays (SaveDraft keeps it), the slug lands.
        XCTAssertEqual(savedDrafts(cli).last?["slug"] as? String, "acme")
    }

    func testLeavingDuringSignInStillConnects() async {
        let googleDraft = #"{"company":"Acme","services":["google"],"step":"google","slack":{},"#
            + #""google":{"client_id":"1234-abcd.apps.googleusercontent.com","client_secret":"sample-secret"}}"#
        let (model, cli) = await resume(googleDraft)
        cli.hold(["company", "check", "google"])
        let check = Task { await model.next() }
        await cli.waitFor(["company", "check", "google"])
        await model.leave()
        cli.release(["company", "check", "google"], [googleOK])
        await check.value
        XCTAssertTrue(model.isChecked(.google))
        XCTAssertEqual(model.connectedAs[.google], "alice@example.com")
        XCTAssertEqual(model.draft.google?.domain, "example.com")
        XCTAssertEqual(model.marks()[.vendor(.google)], .done)

        // A sign-in that never returns leaves the step at its check on return.
        let (stuck, stuckCLI) = await resume(googleDraft)
        stuckCLI.hold(["company", "check", "google"])
        _ = Task { await stuck.check(.google) }
        await stuckCLI.waitFor(["company", "check", "google"])
        await stuck.leave()
        XCTAssertEqual(stuck.checks[.google], .running)
        XCTAssertEqual(stuck.checkLine(.google), Model.checkingGoogle)
        XCTAssertFalse(stuck.primary.enabled)
        stuckCLI.release(["company", "check", "google"], [])
    }

    func testQuitDuringCheckResumesBeforeCheck() async {
        // The check never answered (the app quit): the draft has no mark.
        let (model, _) = await resume(atlassianDraft, checked: [])
        XCTAssertEqual(model.current, .vendor(.atlassian))
        XCTAssertFalse(model.isChecked(.atlassian))
        XCTAssertEqual(model.primary, .init(title: "Check by signing in", enabled: true))
    }

    // MARK: - Existing apps first

    func testFoundAppIsDefault() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"google","client_id":"1234-abcd.apps.googleusercontent.com","#
            + #""label":"acme-watchtower · 1234-abcd.apps.googleusercontent.com","source":"stored","#
            + #""source_label":"Acme's saved company setup"},{"vendor":"google","client_id":"5678-efgh.apps.googleusercontent.com","#
            + #""label":"5678-efgh.apps.googleusercontent.com","source":"credentials_file","#
            + #""source_label":"the credentials file of alice@example.com","has_secret":true}]}"#])
        let (model, _) = make(cli)
        await model.open()
        await model.next()
        XCTAssertEqual(model.current, .vendor(.google))
        XCTAssertEqual(model.phase(.google), .found)
        XCTAssertEqual(model.candidates(for: .google).first?.sourceLabel, "Acme's saved company setup")
        XCTAssertEqual(model.primary.title, "Use the selected client")
        await model.next()
        XCTAssertEqual(model.draft.google?.clientID, "1234-abcd.apps.googleusercontent.com", "the first is the default")
        XCTAssertEqual(model.phase(.google), .reuseSecret)
        XCTAssertFalse(model.primary.enabled, "Continue waits for the secret")
        model.setField(.google, .clientSecret, "sample-secret")
        XCTAssertTrue(model.primary.enabled)
    }

    func testNothingFoundOffersCreateOrExisting() async {
        let (model, _) = make()
        await model.open()
        model.toggle(.microsoft)
        await model.next()
        XCTAssertEqual(model.phase(.microsoft), .nothingFound)
        await model.next()
        XCTAssertEqual(model.phase(.microsoft), .create, "Create new is the default")
        model.back()
        model.goTo(.vendor(.microsoft))
        model.alreadyHaveSelected[.microsoft] = true
        model.alreadyHaveOne()
        XCTAssertEqual(model.phase(.microsoft), .existing)
    }

    // MARK: - Slack step

    func testResumeAfterCreateOffersReuse() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let draft = #"{"company":"","services":["slack"],"step":"slack","slack":{"app_id":"A0ACME"}}"#
        let (model, _) = await resume(draft, cli: cli)
        XCTAssertEqual(model.phase(.slack), .found)
        let first = model.candidates(for: .slack).first
        XCTAssertEqual(first?.label, "Watchtower · A0ACME")
        XCTAssertEqual(first?.sourceLabel, "acme's saved company setup")
        XCTAssertEqual(model.primary.title, "Use Watchtower")
        await model.next()
        await untilObserved { model.current == .denyList }
        XCTAssertTrue(cli.calls(["slack", "app", "create"]).isEmpty, "never a second create")
        XCTAssertEqual(model.marks()[.vendor(.slack)], .done)
    }

    func testSlackStepReadsSetupRecordNotDraft() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let draft = #"{"company":"","services":["slack"],"step":"publish","slack":{"app_id":"A0ACME"}}"#
        let (model, _) = await resume(draft, cli: cli)
        XCTAssertFalse(cli.calls(["slack", "app", "status"]).isEmpty)
        XCTAssertTrue(model.slackAppReady)
        // The summary and the name come from the record, which the draft never copies.
        XCTAssertEqual(model.publishSummary.first, "Slack · Watchtower (A0ACME) in acme")
        XCTAssertEqual(model.derivedName().name, "acme")
        XCTAssertEqual(model.publishName, "acme")
    }

    func testMissingRecordRestartsSlackStep() async {
        // The status read answered and has no record for the draft's app: Look again.
        let draft = #"{"company":"","services":["slack"],"step":"slack","slack":{"app_id":"A0GONE"}}"#
        let (model, _) = await resume(draft)
        XCTAssertTrue(model.slack.recordsRead)
        XCTAssertEqual(model.draft.slack.appID, "")
        XCTAssertEqual(model.phase(.slack), .nothingFound)

        // A failed status read knows nothing: the reference stays.
        let cli = CompanyScriptedCLI()
        cli.on(["slack", "app", "status"], [], exit: 1)
        let (unread, _) = await resume(draft, cli: cli)
        XCTAssertFalse(unread.slack.recordsRead)
        XCTAssertEqual(unread.draft.slack.appID, "A0GONE")
    }

    func testSlackCreateRecordsTheAppAndMovesOn() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        await model.next() // nothing found → Create new
        XCTAssertEqual(model.primary, .init(title: "Create the app", enabled: false))
        model.slackToken = token
        cli.on(["slack", "app", "create"], [#"{"step":"check_token","state":"done"}"#,
                                            #"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
                                                + #""client_id":"1111.2222","link_written":false}"#])
        cli.setups = acmeSetup
        await model.next()
        await untilObserved { model.current == .denyList }
        XCTAssertEqual(model.draft.slack.appID, "A0ACME")
        XCTAssertEqual(model.marks()[.vendor(.slack)], .done)
        let create = cli.calls(["slack", "app", "create"]).first
        XCTAssertEqual(create?.input, token + "\n", "the token on stdin only")
        XCTAssertFalse(create?.args.contains(token) ?? true)
    }

    /// #1142: Create the app on a workspace whose company app this Mac knows
    /// by App ID reads that app with the same token instead of doing nothing.
    func testCreateFindingTheCompanyAppReadsIt() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        await model.next() // nothing found → Create new
        model.slackToken = token
        cli.on(["slack", "app", "create"], [#"{"result":"existing_app","team_id":"T0ACME","team_name":"acme","#
            + #""app_id":"A0ACME","client_id":"1111.2222"}"#])
        cli.on(["slack", "app", "adopt"], [confirmApp])
        await model.next()
        await untilObserved { model.slackDiff != nil }
        XCTAssertEqual(model.slackDiff?.appID, "A0ACME")
        XCTAssertEqual(model.primary.title, "Update the app")
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).first?.args.suffix(5),
                       ["--app-id", "A0ACME", "--client-id", "1111.2222", "--dry-run"])
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).first?.input, token + "\n")
    }

    /// #1142: the company app known only by its Client ID: the step asks for
    /// its settings link, saying why.
    func testCreateFindingAnUnknownCompanyAppAsksForItsLink() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "create"], [#"{"result":"existing_app","team_id":"T0ACME","team_name":"acme","#
            + #""client_id":"1111.2222"}"#])
        await model.next()
        await untilObserved { model.phase(.slack) == .existing }
        XCTAssertTrue(model.slackFoundExisting)
        XCTAssertEqual(model.slackClientID, "1111.2222")
        XCTAssertEqual(Model.slackFoundExisting,
                       "This workspace already has a Watchtower app. Paste its settings link to update it.")
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        XCTAssertFalse(model.slackFoundExisting)
        XCTAssertEqual(model.primary.title, "Continue")
    }

    /// #1142: an app Slack will not let this token change offers a second app;
    /// its create runs with --new-app.
    func testNotCollaboratorOffersANewApp() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"result":"not_collaborator","team_id":"T0ACME","team_name":"acme","#
            + #""code":"no_permission"}"#])
        await model.next()
        await untilObserved { model.slackOffersNewApp }
        model.createNewSlackApp()
        XCTAssertFalse(model.slackOffersNewApp)
        XCTAssertNil(model.slackProblem)
        XCTAssertEqual(model.primary, .init(title: "Create the app", enabled: true), "the token stays")
        cli.on(["slack", "app", "create"], [#"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0NEW","#
            + #""client_id":"3333.4444","link_written":false}"#])
        cli.setups = acmeSetup
        await model.next()
        await untilObserved { model.current == .denyList }
        XCTAssertEqual(cli.calls(["slack", "app", "create"]).first?.args, ["slack", "app", "create", "--json", "--new-app"])
    }

    /// #1142, the owner's dead end end to end: create → existing_app → the
    /// app's read refused (no_permission) → Create a new app instead → --new-app.
    func testExistingAppRefusedThenNewApp() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "create"], [#"{"result":"existing_app","team_id":"T0ACME","team_name":"acme","#
            + #""app_id":"A0ACME","client_id":"1111.2222"}"#])
        cli.on(["slack", "app", "adopt"], [#"{"result":"not_collaborator","team_id":"T0ACME","team_name":"acme","#
            + #""code":"no_permission"}"#])
        await model.next()
        await settled(model) // the create, then the read it chains
        XCTAssertTrue(model.slackOffersNewApp)
        XCTAssertEqual(model.primary.title, "Try again")
        model.createNewSlackApp()
        cli.on(["slack", "app", "create"], [#"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0NEW","#
            + #""client_id":"3333.4444","link_written":false}"#])
        cli.setups = acmeSetup
        await model.next()
        await settled(model)
        XCTAssertEqual(model.current, .denyList)
        XCTAssertEqual(cli.calls(["slack", "app", "create"]).map(\.args),
                       [["slack", "app", "create", "--json"], ["slack", "app", "create", "--json", "--new-app"]])
    }

    /// #1142: Skip while the create's records are read: the found app is not
    /// read behind the owner's back.
    func testExistingAppAfterSkipStartsNothing() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        await model.next()
        model.slackToken = token
        cli.hold(["slack", "app", "status"])
        cli.on(["slack", "app", "create"], [#"{"result":"existing_app","team_id":"T0ACME","team_name":"acme","#
            + #""app_id":"A0ACME","client_id":"1111.2222"}"#])
        let statusReads = cli.calls(["slack", "app", "status"]).count
        await model.next()
        await cli.waitFor(["slack", "app", "status"], count: statusReads + 1) // the create's own records read
        await model.skip()
        cli.release(["slack", "app", "status"], [#"{"setups":[]}"#])
        await settled(model)
        XCTAssertTrue(cli.calls(["slack", "app", "adopt"]).isEmpty)
        XCTAssertFalse(model.slack.isRunning)
    }

    /// Waits out the Slack run and any run its outcome chains.
    private func settled(_ model: CompanySetupWizardModel) async {
        repeat { await model.slack.runTask?.value } while model.slack.isRunning
    }

    func testReusedAppShowsDiffThenUpdates() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"slack","client_id":"1111.2222","app_id":"A0ACME","#
            + #""label":"Watchtower · A0ACME","source":"account","source_label":"Slack app — your connected account acme"}]}"#])
        let (model, _) = make(cli)
        await model.open()
        await model.next()
        XCTAssertEqual(model.primary.title, "Use Watchtower")
        await model.next()
        XCTAssertEqual(model.phase(.slack), .create)
        XCTAssertEqual(model.primary.title, "Continue", "reuse: the token form's action is Continue")
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"step":"check_token","state":"done"}"#, #"{"step":"read_app","state":"done"}"#,
                                           #"{"result":"confirm_app","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
                                               + #""app_name":"Watchtower","client_id":"1111.2222","changes":{"add_scopes":"#
                                               + #"["reactions:read","users:read.email"],"add_redirect_urls":"#
                                               + #"["http://127.0.0.1:18551/slack/callback"],"enable_pkce":false}}"#])
        await model.next()
        await untilObserved { model.slackDiff != nil }
        XCTAssertEqual(model.slackDiff?.appID, "A0ACME")
        XCTAssertEqual(model.slackDiff?.lines, ["Add scopes: reactions:read, users:read.email",
                                                "Add redirect URL: http://127.0.0.1:18551/slack/callback"])
        XCTAssertEqual(Model.manifestDiffTitle("A0ACME"), "App A0ACME's settings differ from Watchtower's")
        XCTAssertEqual(model.primary.title, "Update the app")
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).first?.args,
                       ["slack", "app", "adopt", "--json", "--enable-pkce", "--app-id", "A0ACME", "--client-id", "1111.2222",
                        "--dry-run"], "the first run only reads the app")
        cli.setups = acmeSetup
        cli.on(["slack", "app", "adopt"], [#"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
            + #""client_id":"1111.2222","link_written":true}"#])
        await model.next()
        await untilObserved { model.current == .denyList }
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).last?.args.contains("--confirm-app-id"), true)
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).last?.args.contains("--dry-run"), false, "Update the app changes it")
        XCTAssertEqual(model.marks()[.vendor(.slack)], .reused)
        XCTAssertTrue(cli.calls(["slack", "app", "create"]).isEmpty)
    }

    private let confirmApp = #"{"result":"confirm_app","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
        + #""app_name":"Watchtower","client_id":"1111.2222","changes":{"add_scopes":["reactions:read"]}}"#

    /// The settings link's app, through the token form to the diff.
    private func slackAtDiff() async -> (Model, CompanyScriptedCLI) {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [confirmApp])
        await model.next()
        await untilObserved { model.slackDiff != nil }
        return (model, cli)
    }

    func testBackFromDiffNeverConfirms() async {
        let (model, cli) = await slackAtDiff()
        model.back()
        XCTAssertNil(model.slackDiff)
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        cli.on(["slack", "app", "adopt"], [confirmApp])
        await model.next()
        await untilObserved { model.slackDiff != nil }
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).count, 2)
        XCTAssertFalse(cli.calls(["slack", "app", "adopt"]).last?.args.contains("--confirm-app-id") ?? true,
                       "only Update the app confirms the App ID")
    }

    func testUnknownAppLinkSaysSo() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0NOPE")
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"result":"app_not_found","team_id":"T0ACME","team_name":"acme"}"#])
        await model.next()
        await untilObserved { model.slackProblem != nil }
        XCTAssertEqual(model.slackProblem, "Slack has no app A0NOPE this token can see. Check the link and paste it again.")
        XCTAssertEqual(model.primary.title, "Try again")
        await model.next()
        XCTAssertEqual(model.phase(.slack), .existing, "back to the link field")
        XCTAssertNil(model.slackProblem)
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).count, 1, "Try again does not repeat the same request")
    }

    func testSettingsLinkAdoptsWithClientID() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://acme.slack.com/apps")
        XCTAssertTrue(model.slackSettingsLinkInvalid)
        XCTAssertFalse(model.primary.enabled, "Continue waits for a valid link")
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        model.setField(.slack, .clientID, "1111.2222")
        XCTAssertFalse(model.slackSettingsLinkInvalid)
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [confirmApp])
        await model.next()
        await untilObserved { model.slackDiff != nil }
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).first?.args.suffix(5),
                       ["--app-id", "A0ACME", "--client-id", "1111.2222", "--dry-run"])
    }

    func testMatchingAppShowsNoDiffLines() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"result":"confirm_app","team_id":"T0ACME","app_id":"A0ACME","changes":{}}"#])
        await model.next()
        await untilObserved { model.slackDiff != nil }
        XCTAssertEqual(model.slackDiff?.lines, [])
        XCTAssertEqual(Model.manifestSameTitle("A0ACME"), "App A0ACME already has Watchtower's settings")
    }

    func testDiscoveryFailureIsNotNothingFound() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [], exit: 1)
        let (model, _) = make(cli)
        await model.open()
        XCTAssertTrue(model.discoveryFailed)
        XCTAssertEqual(Model.discoveryFailed, "Watchtower could not look for the apps this Mac already knows. You can still "
            + "create one or paste what identifies yours.")
        let (fine, _) = make()
        await fine.open()
        XCTAssertFalse(fine.discoveryFailed)
    }

    func testDiscardStartsFresh() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"linear","client_id":"lin","label":"lin","#
            + #""source":"account","source_label":"Linear app — your connected account acme"}]}"#])
        let (model, _) = make(cli)
        await model.open()
        model.hostField = "https://bad"
        model.addHost()
        model.toggle(.slack)
        model.setField(.slack, .slackSettingsLink, "nope")
        await model.discard()
        XCTAssertEqual(model.hostField, "")
        XCTAssertFalse(model.hostInvalid)
        XCTAssertEqual(model.slackSettingsLink, "")
        XCTAssertEqual(model.ticked, [.linear], "found apps are pre-ticked again")
    }

    func testFailedFirstCheckLeavesTheNameFree() async {
        let draft = atlassianDraft.replacingOccurrences(of: #""company":"Acme""#, with: #""company":"""#)
        let (model, cli) = await resume(draft)
        cli.on(["company", "check", "atlassian"], [#"{"result":"rejected","code":"invalid_client"}"#])
        await model.check(.atlassian)
        XCTAssertTrue(cli.calls(["company", "check"]).first?.input.contains("\"company\":\"Acme\"") ?? false)
        XCTAssertEqual(model.draft.company, "", "nothing was stored under the derived name")
    }

    func testDiscardDuringPreCheckSaveLandsNothing() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.hold(["company", "draft", "save"])
        let check = Task { await model.check(.atlassian) }
        await cli.waitFor(["company", "draft", "save"])
        let discard = Task { await model.discard() }
        cli.release(["company", "draft", "save"], [])
        await check.value
        await discard.value
        XCTAssertTrue(cli.calls(["company", "check"]).isEmpty, "the discarded setup is never checked")
        let order = cli.calls.map { $0.args.prefix(3).joined(separator: " ") }
        XCTAssertLessThan(order.lastIndex(of: "company draft save") ?? .max, order.lastIndex(of: "company draft discard") ?? -1,
                          "the discard runs after the save in flight, so the draft stays deleted")
        XCTAssertNil(model.checks[.atlassian])
    }

    func testNotCollaboratorKeepsStepOpen() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://acme.slack.com/apps")
        await model.next()
        XCTAssertTrue(model.slackSettingsLinkInvalid)
        XCTAssertEqual(Model.slackSettingsInvalid, "That is not a Slack app settings link. It looks like "
            + "https://api.slack.com/apps/A0123ABCD.")
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME/general")
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"result":"not_collaborator","team_id":"T0ACME","team_name":"acme"}"#])
        await model.next()
        await untilObserved { model.slackProblem != nil }
        XCTAssertEqual(model.slackProblem, "Slack would not let this token change app A0ACME (no_permission). The token has to "
            + "come from the workspace the app was made in, from one of its collaborators: make a new token there and try "
            + "again.")
        XCTAssertEqual(model.current, .vendor(.slack), "the step stays open")
        XCTAssertEqual(model.primary.title, "Try again")
        XCTAssertTrue(cli.calls(["slack", "app", "create"]).isEmpty, "nothing created")
        XCTAssertEqual(model.marks()[.vendor(.slack)], .notStarted)
    }

    func testWrongWorkspaceRefused() async {
        let cli = CompanyScriptedCLI()
        let (model, _) = make(cli)
        await model.open()
        model.toggle(.slack)
        await model.next()
        model.alreadyHaveOne()
        model.setField(.slack, .slackSettingsLink, "https://api.slack.com/apps/A0ACME")
        await model.next()
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"result":"wrong_workspace","team_id":"T0ACME","team_name":"acme","#
            + #""app_id":"A0ACME","app_team_id":"T0OTHER"}"#])
        await model.next()
        await untilObserved { model.slackProblem != nil }
        XCTAssertEqual(model.slackProblem, "App A0ACME belongs to another workspace (T0OTHER), not acme. "
            + "Check the link and paste it again.")
        XCTAssertEqual(model.current, .vendor(.slack))

        // Per-vendor dry checks refuse a wrong tenant or id at the step.
        let (ms, msCLI) = make()
        await ms.open()
        ms.toggle(.microsoft)
        await ms.next()
        await ms.next()
        ms.setField(.microsoft, .clientID, "4b1e0c9d-0000-4f00-a000-00000000077a")
        ms.setField(.microsoft, .tenantID, "0000-acme")
        msCLI.on(["company", "check", "microsoft"], [#"{"result":"rejected","code":"AADSTS700016"}"#])
        await ms.next()
        XCTAssertEqual(ms.checkLine(.microsoft), "Microsoft does not accept this client in tenant 0000-acme: AADSTS700016. "
            + "Check both ids on the app's Overview page.")
        XCTAssertEqual(ms.current, .vendor(.microsoft))
    }

    // MARK: - Atlassian

    func testAtlassianStepNeedsSignInToken() async {
        let (model, cli) = await resume(atlassianDraft)
        XCTAssertEqual(model.primary.title, "Check by signing in")
        cli.on(["company", "check", "atlassian"], [#"{"result":"rejected","code":"invalid_client","message":"bad"}"#])
        await model.next()
        XCTAssertEqual(model.checkLine(.atlassian), "Atlassian refused the sign-in: invalid_client. Check the client id and "
            + "secret, and that Watchtower's callback URLs are in the app's Authorization settings.")
        XCTAssertEqual(model.current, .vendor(.atlassian), "the step stays open")
        XCTAssertEqual(model.primary.title, "Try again")
        XCTAssertFalse(model.isChecked(.atlassian))
        XCTAssertEqual(model.publishBlockedReason, Model.publishWaitsAtlassian)
        // The check's input: the company and the pair on stdin, never argv.
        let call = cli.calls(["company", "check", "atlassian"]).first
        XCTAssertEqual(call?.args, ["company", "check", "atlassian", "--json", "--app-return"])
        XCTAssertTrue(call?.input.contains("\"client_secret\":\"sample-secret\"") ?? false)
        XCTAssertTrue(call?.input.contains("\"company\":\"Acme\"") ?? false)
        // The draft was saved before the check, so Go marks exactly these values.
        XCTAssertLessThan(cli.calls.lastIndex { $0.args.starts(with: ["company", "draft", "save"]) } ?? .max,
                          cli.calls.lastIndex { $0.args.starts(with: ["company", "check"]) } ?? -1)
    }

    func testAtlassianNeedsAllThreeChecks() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [atlassianOK])
        await model.next()
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertEqual(model.current, .vendor(.atlassian), "the confirm checklist follows")
        XCTAssertEqual(model.primary, .init(title: "Continue", enabled: false))
        model.atlassianConfirmed = [true, true, false]
        XCTAssertFalse(model.primary.enabled)
        XCTAssertEqual(model.publishBlockedReason, "Publish waits for the Atlassian settings: tick the three items on the "
            + "Atlassian step.", "a check reached from the rail later still needs the checklist")
        model.atlassianConfirmed = [true, true, true]
        XCTAssertTrue(model.primary.enabled)
        XCTAssertNil(model.publishBlockedReason)
        await model.next()
        XCTAssertEqual(model.current, .denyList)
    }

    func testPublishDisabledUntilAtlassianChecked() async {
        let draft = #"{"company":"Acme","services":["atlassian"],"step":"publish","slack":{},"atlassian":{"#
            + #""client_id":"9f3a8d0e4b7c21","client_secret":"sample-secret","site":"https://acme.atlassian.net","#
            + #""confluence":true}}"#
        let (model, _) = await resume(draft)
        XCTAssertEqual(model.publishBlockedReason, "Publish waits for the Atlassian check: sign in on the Atlassian step, "
            + "or skip Atlassian.")
        XCTAssertFalse(model.primary.enabled)
        // Skipping Atlassian removes the reason.
        model.goTo(.vendor(.atlassian))
        await model.skip()
        model.goTo(.publish)
        XCTAssertNil(model.publishBlockedReason)
        XCTAssertTrue(model.primary.enabled)
        XCTAssertTrue(model.publishSummary.contains("Atlassian · skipped: colleagues connect Jira with their own API token"))
    }

    func testCheckSignInCreatesCompanyAccount() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [#"{"step":"ignored"}"#, "Open this URL in your browser…", atlassianOK])
        await model.check(.atlassian)
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertEqual(model.connectedAs[.atlassian], "alice@example.com")
        XCTAssertEqual(model.checkLine(.atlassian), "Connected as alice@example.com")
        XCTAssertEqual(model.marks()[.vendor(.atlassian)], .done)
    }

    func testFirstCheckStoresBundle() async {
        // The first check sends the company name (derived) so Go stores
        // company/<slug>.json; the slug it chose lands in the draft.
        let draft = #"{"company":"","services":["atlassian"],"step":"atlassian","slack":{},"atlassian":{"#
            + #""client_id":"9f3a8d0e4b7c21","client_secret":"sample-secret","site":"https://acme.atlassian.net","#
            + #""confluence":true}}"#
        let (model, cli) = await resume(draft)
        cli.on(["company", "check", "atlassian"], [atlassianOK])
        await model.check(.atlassian)
        XCTAssertTrue(cli.calls(["company", "check"]).first?.input.contains("\"company\":\"Acme\"") ?? false,
                      "the name derived from the Atlassian site")
        XCTAssertEqual(model.draft.company, "Acme")
        XCTAssertEqual(model.draft.slug, "acme")
        // The next check names the stored company by its slug.
        model.setField(.atlassian, .clientSecret, "rotated")
        cli.on(["company", "check", "atlassian"], [atlassianOK])
        await model.check(.atlassian)
        XCTAssertTrue(cli.calls(["company", "check"]).last?.input.contains("\"slug\":\"acme\"") ?? false)
    }

    func testEditingCheckedFieldClearsCheck() async {
        let (model, _) = await resume(atlassianDraft, checked: ["atlassian"])
        XCTAssertTrue(model.isChecked(.atlassian))
        model.setField(.atlassian, .clientSecret, "another-secret")
        XCTAssertFalse(model.isChecked(.atlassian))
        XCTAssertEqual(model.marks()[.vendor(.atlassian)], .notStarted)
        XCTAssertEqual(model.primary.title, "Check by signing in")
    }

    func testSameValuesKeepCheck() async {
        let (model, _) = await resume(atlassianDraft, checked: ["atlassian"])
        model.setField(.atlassian, .clientSecret, "another-secret")
        model.setField(.atlassian, .clientSecret, "sample-secret")
        XCTAssertTrue(model.isChecked(.atlassian))
    }

    func testPublishDisabledAfterEditOfCheckedStep() async {
        let draft = atlassianDraft.replacingOccurrences(of: #""step":"atlassian""#, with: #""step":"publish""#)
        let (model, _) = await resume(draft, checked: ["atlassian"])
        XCTAssertNil(model.publishBlockedReason)
        model.setField(.atlassian, .clientID, "7b20aaaa0e04")
        XCTAssertEqual(model.publishBlockedReason, Model.publishWaitsAtlassian)
    }

    func testEditThenRecheckRelogsSameAccount() async {
        let (model, cli) = await resume(atlassianDraft, checked: ["atlassian"])
        model.setField(.atlassian, .clientID, "7b20aaaa0e04")
        cli.on(["company", "check", "atlassian"], [#"{"result":"replace_needed","slug":"acme","code":"client_id"}"#])
        await model.next()
        XCTAssertEqual(model.checks[.atlassian], .replaceNeeded)
        cli.on(["company", "check", "atlassian"], [atlassianOK])
        XCTAssertEqual(model.primary.title, "Replace and sign in")
        await model.next()
        XCTAssertEqual(cli.calls(["company", "check", "atlassian"]).last?.args.last, "--replace")
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertEqual(model.connectedAs[.atlassian], "alice@example.com", "Go re-logs the same account (account_id 7)")
    }

    func testEditWithoutRecheckKeepsOldPair() async {
        // Nothing is stored by an edit: no check runs, only the draft changes.
        let (model, cli) = await resume(atlassianDraft, checked: ["atlassian"])
        model.setField(.atlassian, .clientSecret, "another-secret")
        await model.leave()
        XCTAssertTrue(cli.calls(["company", "check"]).isEmpty)
        XCTAssertTrue(cli.calls(["company", "publish"]).isEmpty)
        XCTAssertFalse(model.isChecked(.atlassian))
    }

    func testCheckOverStoredCompanyActsAsReplace() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [#"{"result":"replace_needed","slug":"acme","code":"client_id","#
            + #""message":"Acme's stored atlassian app will be replaced"}"#])
        await model.next()
        XCTAssertEqual(model.checkLine(.atlassian), "Acme's stored Atlassian app will be replaced; your other Acme "
            + "Atlassian accounts will need to log in again.")
        XCTAssertFalse(model.isChecked(.atlassian), "nothing stored without --replace")
        XCTAssertFalse(cli.calls(["company", "check"]).first?.args.contains("--replace") ?? true)
    }

    func testGoogleCheckIsSignIn() async {
        let (model, cli) = make()
        await model.open()
        model.toggle(.google)
        await model.next()
        await model.next() // Create new
        XCTAssertFalse(model.primary.enabled, "Continue waits for the JSON")
        XCTAssertFalse(model.dropGoogleClient(Data("{}".utf8), fileName: "x.json"))
        XCTAssertTrue(model.googleFileProblem)
        let json = #"{"installed":{"client_id":"1234-abcd.apps.googleusercontent.com","client_secret":"sample-secret","#
            + #""project_id":"acme-watchtower"}}"#
        XCTAssertTrue(model.dropGoogleClient(Data(json.utf8), fileName: "client_secret_1234-abcd.json"))
        XCTAssertEqual(model.droppedGoogleLine, "client_secret_1234-abcd.json · project acme-watchtower")
        model.publishName = "Acme"
        cli.on(["company", "check", "google"], [#"{"result":"rejected","code":"invalid_client"}"#])
        await model.next()
        XCTAssertEqual(model.checkLine(.google), "Google does not accept this client: invalid_client. Download the JSON "
            + "again from Credentials.")
        XCTAssertEqual(cli.calls(["company", "check", "google"]).first?.args, ["company", "check", "google", "--json", "--app-return"])
        cli.on(["company", "check", "google"], [#"{"result":"network","message":"the request timed out"}"#])
        await model.next()
        XCTAssertEqual(model.checkLine(.google), "Could not reach Google: the request timed out. Nothing was saved.")
    }

    func testCheckNeedsACompanyName() async {
        // Nothing to derive the name from yet (no Slack, no domain, no site).
        let draft = #"{"company":"","services":["google"],"step":"google","slack":{},"#
            + #""google":{"client_id":"1234-abcd.apps.googleusercontent.com","client_secret":"sample-secret"}}"#
        let (model, cli) = await resume(draft)
        await model.check(.google)
        XCTAssertTrue(cli.calls(["company", "check"]).isEmpty)
        XCTAssertEqual(model.checkLine(.google), Model.nameNeeded)
    }

    func testNoOrgAccessShowsStepsForAdmin() async {
        let (model, cli) = make()
        await model.open()
        model.toggle(.google)
        await model.next()
        await model.next()
        model.showNoOrgAccess()
        XCTAssertEqual(model.phase(.google), .noOrgAccess)
        XCTAssertEqual(Model.noOrgTitle, "An Internal app needs your company's Google Cloud organization")
        XCTAssertEqual(Model.noOrgBody(domain: "example.com"), "The project must sit inside example.com's Google Cloud "
            + "organization. If you cannot create one there, or Internal is not offered, ask your Google Workspace admin to "
            + "create the project or to give you the Project Creator role. Then drop the client JSON they send you here.")
        let steps = Model.adminSteps(.google)
        XCTAssertTrue(steps.hasPrefix("1. Create a project — https://console.cloud.google.com/projectcreate"))
        XCTAssertEqual(steps.split(separator: "\n").count, 4)
        XCTAssertTrue(cli.calls(["company", "check"]).isEmpty, "nothing stored")
        XCTAssertFalse(model.primary.enabled, "Continue waits for the JSON the admin sends")
    }

    func testMicrosoftWaitingForConsentDoesNotBlockPublish() async {
        let draft = #"{"company":"Acme","services":["microsoft"],"step":"microsoft","slack":{},"#
            + #""microsoft":{"client_id":"4b1e0c9d-0000-4f00-a000-00000000077a","tenant_id":"0000-acme"}}"#
        let (model, cli) = await resume(draft)
        let url = "https://login.microsoftonline.com/0000-acme/adminconsent?client_id=4b1e0c9d-0000-4f00-a000-00000000077a"
        cli.on(["company", "check", "microsoft"], [#"{"result":"admin_consent","code":"AADSTS65001","admin_consent_url":"\#(url)"}"#])
        await model.next()
        XCTAssertEqual(model.checks[.microsoft], .adminConsent(url: url))
        XCTAssertEqual(cli.calls(["company", "check", "microsoft"]).first?.args,
                       ["company", "check", "microsoft", "--json", "--client-id", "4b1e0c9d-0000-4f00-a000-00000000077a",
                        "--tenant", "0000-acme"])
        XCTAssertEqual(model.marks()[.vendor(.microsoft)], .waiting)
        XCTAssertEqual(Model.railWord(.waiting), "Waiting")
        XCTAssertEqual(model.primary, .init(title: "Continue", enabled: true), "Continue is allowed")
        await model.next()
        XCTAssertEqual(model.current, .denyList)
        model.goTo(.publish)
        XCTAssertNil(model.publishBlockedReason)
        XCTAssertTrue(model.publishSummary.contains("Microsoft 365 · client 4b1e…77a · tenant 0000-acme · waiting for admin consent"))
        XCTAssertEqual(savedDrafts(cli).last?["microsoft_waiting"] as? Bool, true)
        // Check again once consent exists: done.
        model.goTo(.vendor(.microsoft))
        cli.on(["company", "check", "microsoft"], [#"{"result":"ok","checked":true}"#])
        await model.check(.microsoft)
        XCTAssertEqual(model.marks()[.vendor(.microsoft)], .done)
    }

    // MARK: - Unreadable draft, discard

    func testUnreadableDraftIsRenamedNotDeleted() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [#"{"state":"unreadable","draft":null,"bad_file":"draft.json.bad-20261118T041200Z","#
            + #""checked_vendors":[]}"#])
        let (model, _) = make(cli)
        await model.open()
        XCTAssertEqual(model.draftUnreadable?.title, "Your unfinished setup could not be read — start again")
        XCTAssertEqual(model.draftUnreadable?.body, "Watchtower kept the file as draft.json.bad-20261118T041200Z next to your "
            + "company setups, so nothing you typed is lost; Discard or Publish deletes it.")
        XCTAssertEqual(model.draftUnreadable?.file, "draft.json.bad-20261118T041200Z")
        XCTAssertTrue(cli.calls(["company", "draft", "discard"]).isEmpty, "never deleted by opening")
        await model.discard()
        XCTAssertNil(model.draftUnreadable, "Discard deletes it (Go deletes every .bad-*)")
    }

    func testUnreadableDraftIsNotNoDraft() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [#"{"state":"unreadable","draft":null,"bad_file":"draft.json.bad-x","checked_vendors":[]}"#])
        let (model, _) = make(cli)
        await model.open()
        XCTAssertEqual(model.current, .services, "the page opens on Services")
        XCTAssertNotNil(model.draftUnreadable)
        XCTAssertNil(model.resumeLine)
        let (fresh, _) = make()
        await fresh.open()
        XCTAssertNil(fresh.draftUnreadable)
    }

    func testDiscardDeletesDraft() async {
        let (model, cli) = await resume(atlassianDraft)
        XCTAssertEqual(Model.discardConfirm, "Discard this setup? The draft and the secrets in it are deleted from this Mac. "
            + "Services you already signed in to stay connected and keep working. Apps you created stay in Slack, Google, "
            + "Atlassian, Linear and Microsoft.")
        await model.discard()
        XCTAssertEqual(cli.calls(["company", "draft", "discard"]).count, 1)
        XCTAssertNil(model.draft.atlassian)
        XCTAssertEqual(model.current, .services)
        XCTAssertNil(model.resumeLine)
    }

    func testDiscardKeepsCheckedAccountsAndBundle() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [atlassianOK])
        await model.check(.atlassian)
        await model.discard()
        // Only the draft goes: no publish, no account or company verb runs.
        let verbs = cli.calls.map { Array($0.args.prefix(3)) }
        XCTAssertEqual(verbs.filter { $0.first == "company" && $0.count > 1 && !["draft", "discover", "check"].contains($0[1]) }, [])
        XCTAssertEqual(cli.calls(["company", "draft", "discard"]).count, 1)
    }

    func testDraftReadFailureNeverOverwrites() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [], exit: 1)
        let (model, _) = make(cli)
        await model.open()
        XCTAssertEqual(model.load, .notOpened, "the next open reads again")
        XCTAssertNotNil(model.storageProblem)
        model.toggle(.slack)
        await model.leave()
        XCTAssertTrue(cli.calls(["company", "draft", "save"]).isEmpty, "a draft it could not read is never overwritten")
        await model.open()
        XCTAssertEqual(model.load, .ready)
        XCTAssertNil(model.storageProblem)
    }

    func testPreTicksAloneMakeNoDraft() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"linear","client_id":"lin","label":"lin","#
            + #""source":"account","source_label":"Linear app — your connected account acme"}]}"#])
        let (model, _) = make(cli)
        await model.open()
        XCTAssertEqual(model.ticked, [.linear])
        await model.leave()
        XCTAssertTrue(cli.calls(["company", "draft", "save"]).isEmpty, "no Setup in progress for a page only looked at")
        XCTAssertNil(model.resumeLine)
    }

    func testDiscardDuringCheckLandsNothing() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.hold(["company", "check", "atlassian"])
        let check = Task { await model.check(.atlassian) }
        await cli.waitFor(["company", "check", "atlassian"])
        await model.discard()
        let saves = cli.calls(["company", "draft", "save"]).count
        cli.release(["company", "check", "atlassian"], [atlassianOK])
        await check.value
        XCTAssertNil(model.draft.atlassian)
        XCTAssertEqual(model.draft.slug, "")
        XCTAssertEqual(cli.calls(["company", "draft", "save"]).count, saves, "a discarded draft is not written back")
    }

    func testDiscardFailureSaysSo() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "draft", "discard"], [], exit: 1)
        await model.discard()
        XCTAssertNotNil(model.storageProblem)
        XCTAssertNotNil(model.draft.atlassian, "nothing is reset when the draft is still there")
    }

    func testQuitAfterCheckKeepsAccount() async {
        // The check stored the bundle and marked the draft; a new run sees it checked.
        let (model, _) = await resume(atlassianDraft.replacingOccurrences(of: #""company":"Acme""#,
                                                                          with: #""company":"Acme","slug":"acme""#),
                                      checked: ["atlassian"])
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertEqual(model.draft.slug, "acme")
        XCTAssertEqual(model.marks()[.vendor(.atlassian)], .done)
    }

    // MARK: - Publish

    private let publishDraft = #"{"company":"Acme","slug":"acme","services":["slack","atlassian","linear"],"#
        + #""step":"publish","slack":{"app_id":"A0ACME"},"atlassian":{"client_id":"9f3a8d0e4b7c21","#
        + #""client_secret":"sample-secret","site":"https://acme.atlassian.net","confluence":true},"skipped":["linear"],"#
        + #""deny_hosts":["intranet.example.com","wiki.corp.example.com"]}"#

    private func publishReady() async -> (Model, CompanyScriptedCLI) {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        return await resume(publishDraft, checked: ["atlassian"], cli: cli)
    }

    func testPublishSummary() async {
        let (model, _) = await publishReady()
        XCTAssertEqual(model.publishSummary, [
            "Slack · Watchtower (A0ACME) in acme",
            "Google · not used: colleagues can connect Google Calendar; Gmail needs their own Google project",
            "Atlassian · client 9f3a…c21 · acme.atlassian.net · Confluence on · checked and connected by your sign-in",
            "Linear · skipped: colleagues use Watchtower's shared Linear app",
            "Microsoft 365 · not used: colleagues use Watchtower's shared Microsoft app, which your tenant may ask an admin "
                + "to approve",
            "Link deny list · 2 hosts"
        ])
        XCTAssertEqual(model.publishName, "Acme")
        XCTAssertEqual(model.companyNameHelp, "Colleagues see “Connect Acme?”. Taken from your Slack workspace; change it if "
            + "people know the company by another name.")
        XCTAssertTrue(model.publishNeedsToken, "a resumed draft has no token")
        XCTAssertFalse(model.primary.enabled)
    }

    func testPublishDoneOffersLinkCodeProfile() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        cli.on(["company", "publish"], [#"{"step":"pack","state":"running"}"#, #"{"step":"pack","state":"done"}"#,
                                        #"{"step":"write_link","state":"done"}"#,
                                        #"{"result":"ok","slug":"acme","link":"http://127.0.0.1:18551/company/connect?b=eyJ2","#
                                            + #""code":"eyJ2"}"#])
        await model.next()
        XCTAssertEqual(model.publishState, .done(.init(slug: "acme", link: "http://127.0.0.1:18551/company/connect?b=eyJ2",
                                                       code: "eyJ2", onSlackPage: true)))
        XCTAssertEqual(model.publishSteps.map(\.mark), [.done, .done])
        XCTAssertEqual(model.publishSteps.map(\.label), ["Packing the company setup", "Writing the link to the Slack app's About page"])
        XCTAssertEqual(model.marks()[.publish], .done)
        XCTAssertEqual(model.slackToken, "", "the token is dropped once published")
        let call = cli.calls(["company", "publish"]).first
        XCTAssertEqual(call?.args, ["company", "publish", "--json"])
        XCTAssertEqual(call?.input, #"{"company":"Acme","config_token":"\#(token)"}"#)
        XCTAssertEqual(Model.publishedTitle("Acme"), "Acme is set up")
        XCTAssertEqual(Model.profileFileName("Acme"), "Acme-Watchtower.mobileconfig")
        cli.on(["company", "profile"], ["<?xml version=\"1.0\"?>", "<plist/>"])
        let profile = await model.profile()
        XCTAssertEqual(profile.flatMap { String(data: $0, encoding: .utf8) }, "<?xml version=\"1.0\"?>\n<plist/>\n")
        XCTAssertEqual(cli.calls(["company", "profile"]).first?.args, ["company", "profile", "--slug", "acme"])
    }

    func testPublishTokenExpiredKeepsSetup() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        cli.on(["company", "publish"], [#"{"step":"pack","state":"done"}"#, #"{"step":"write_link","state":"failed"}"#,
                                        #"{"result":"token_expired","slug":"acme","message":"expired"}"#])
        await model.next()
        XCTAssertEqual(model.publishState, .tokenExpired)
        XCTAssertEqual(Model.publishTokenExpiredLine, "The configuration token has expired, so the link is not on the Slack "
            + "page yet. Your setup is kept. Generate a fresh token and paste it.")
        XCTAssertTrue(model.publishNeedsToken, "a fresh token is asked")
        XCTAssertTrue(cli.calls(["company", "draft", "discard"]).isEmpty, "the setup is kept")
        XCTAssertNotNil(model.draft.atlassian)
        XCTAssertEqual(model.primary.title, "Try again")
    }

    func testPublishNetworkFailureKeepsSetup() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        cli.on(["company", "publish"], [#"{"result":"network","message":"Could not reach Slack: the request timed out. "#
            + #"Your setup is kept."}"#])
        await model.next()
        XCTAssertEqual(model.publishState, .failed("Could not reach Slack: the request timed out. Your setup is kept."))
        XCTAssertEqual(model.slackToken, token, "the token stays for Try again")
        XCTAssertEqual(model.primary, .init(title: "Try again", enabled: true))
        // A CLI that dies says so; the setup is kept.
        cli.on(["company", "publish"], [], exit: 1)
        await model.next()
        guard case let .failed(line) = model.publishState else { return XCTFail("not failed") }
        XCTAssertTrue(line.hasSuffix("Your setup is kept; try again."))
    }

    /// Ask #1613: a name edited after a check stored the setup just publishes
    /// (Go changes only the display name; the slug stays).
    func testPublishUnderAnEditedNameJustPublishes() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        model.publishName = "Acme Corp"
        cli.on(["company", "publish"], [#"{"result":"ok","slug":"acme","link":"l","code":"c"}"#])
        await model.next()
        XCTAssertEqual(cli.calls(["company", "publish"]).first?.input, #"{"company":"Acme Corp","config_token":"\#(token)"}"#)
        XCTAssertNil(model.publishRefusal)
        XCTAssertEqual(model.publishState, .done(.init(slug: "acme", link: "l", code: "c", onSlackPage: true)))
    }

    /// Stored under the edited name, then Slack failed: the model's draft takes
    /// the name Go gave the draft, so the next save does not write the old one back.
    func testPublishUnderAnEditedNameKeepsItAfterAFailure() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        model.publishName = "Acme Corp"
        cli.on(["company", "publish"], [#"{"result":"token_expired","slug":"acme","message":"expired"}"#])
        await model.next()
        XCTAssertEqual(model.publishState, .tokenExpired)
        XCTAssertEqual(model.draft.company, "Acme Corp")

        // Refused before anything was stored (no slug): the draft keeps its name.
        let (other, otherCLI) = await publishReady()
        other.slackToken = token
        other.publishName = "Globex"
        otherCLI.on(["company", "publish"], [#"{"result":"refused","reason":"name_taken","message":"taken"}"#])
        await other.next()
        XCTAssertEqual(other.draft.company, "Acme")
    }

    func testPublishNameRefusalsAreClear() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        model.publishName = " Globex "
        cli.on(["company", "publish"], [#"{"result":"refused","reason":"name_taken","#
            + #""message":"\"Globex\" is the name of another company on this Mac (globex); publish under another name"}"#])
        await model.next()
        XCTAssertEqual(model.publishState, .ready)
        XCTAssertEqual(model.publishRefusal, "“Globex” is already the name of another company on this Mac, or of your "
            + "own Google project. Choose another name.")

        cli.on(["company", "publish"], [#"{"result":"refused","reason":"company_forced","message":"forced"}"#])
        await model.next()
        XCTAssertEqual(model.publishRefusal, "Your organization sets this company's name on this Mac, so it cannot be "
            + "changed here.")
    }

    func testPublishWithoutSlackSendsNoToken() async {
        let draft = #"{"company":"Acme","slug":"acme","services":["linear"],"step":"publish","slack":{},"#
            + #""linear":{"client_id":"lin_client_1"}}"#
        let (model, cli) = await resume(draft)
        XCTAssertFalse(model.publishNeedsToken)
        cli.on(["company", "publish"], [#"{"result":"no_slack","slug":"acme","link":"l","code":"c"}"#])
        await model.next()
        XCTAssertEqual(cli.calls(["company", "publish"]).first?.input, #"{"company":"Acme"}"#)
        XCTAssertEqual(model.publishState, .done(.init(slug: "acme", link: "l", code: "c", onSlackPage: false)))
        XCTAssertEqual(model.publishSummary.first, "Slack · not used: no Slack page carries the link")
    }

    func testConnectThisMacOffersOnlyUnconnected() async {
        let draft = #"{"company":"Acme","slug":"acme","services":["slack","google","atlassian","linear","microsoft"],"#
            + #""step":"publish","slack":{"app_id":"A0ACME"},"google":{"client_id":"1234-abcd.apps.googleusercontent.com","#
            + #""client_secret":"s","domain":"example.com"},"atlassian":{"client_id":"9f3a8d0e4b7c21","client_secret":"s","#
            + #""site":"https://acme.atlassian.net","confluence":true},"linear":{"client_id":"lin"},"#
            + #""microsoft":{"client_id":"m","tenant_id":"t"},"skipped":["linear"]}"#
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let (model, _) = await resume(draft, checked: ["google", "atlassian"], cli: cli)
        XCTAssertEqual(model.connectThisMacVendors, [.slack, .microsoft])
    }

    // MARK: - Company name, token, deny list

    func testCompanyNameDerived() async {
        let (model, _) = make()
        await model.open()
        XCTAssertEqual(model.derivedName().name, "")
        model.toggle(.atlassian)
        await model.next()
        model.createNew()
        model.setAtlassianSite("acme.atlassian.net")
        XCTAssertEqual(model.draft.atlassian?.site, "https://acme.atlassian.net")
        XCTAssertEqual(model.derivedName().name, "Acme")
        XCTAssertEqual(model.derivedName().source, .atlassian)
        // The Google domain comes before the Atlassian site…
        let draft = #"{"company":"","services":["google","atlassian"],"step":"publish","slack":{},"#
            + #""google":{"client_id":"g","client_secret":"s","domain":"example.com"},"#
            + #""atlassian":{"client_id":"a","client_secret":"s","site":"https://acme.atlassian.net","confluence":true}}"#
        let (google, _) = await resume(draft)
        XCTAssertEqual(google.derivedName().name, "Example")
        XCTAssertEqual(google.companyNameHelp, "Colleagues see “Connect Example?”. Taken from your Google Workspace domain; "
            + "change it if people know the company by another name.")
        // …and the Slack workspace before both.
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let slackDraft = draft.replacingOccurrences(of: #""slack":{}"#, with: #""slack":{"app_id":"A0ACME"}"#)
        let (slack, _) = await resume(slackDraft, cli: cli)
        XCTAssertEqual(slack.derivedName().name, "acme")
        XCTAssertEqual(slack.derivedName().source, .slack)
    }

    func testTokenNeverInArgv() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        cli.on(["company", "publish"], [#"{"result":"ok","slug":"acme","link":"l","code":"c"}"#])
        await model.next()
        for call in cli.calls {
            XCTAssertFalse(call.args.contains { $0.contains("xoxe") }, call.args.joined(separator: " "))
        }
        for saved in cli.calls(["company", "draft", "save"]) {
            XCTAssertFalse(saved.input.contains("xoxe"), "the draft never carries the token")
        }
    }

    func testDenyListTakesHostNamesOnly() async {
        let (model, _) = make()
        await model.open()
        for bad in ["https://intranet.example.com/home", "*", "example.com/path", "intranet", "10.0.0.1", "-a.example.com"] {
            model.hostField = bad
            model.addHost()
            XCTAssertTrue(model.hostInvalid, bad)
        }
        XCTAssertEqual(Model.denyInvalid, "That is not a host name. Enter it like intranet.example.com, without https:// or a path.")
        model.hostField = " Intranet.Example.com "
        model.addHost()
        XCTAssertFalse(model.hostInvalid)
        XCTAssertEqual(model.draft.denyHosts, ["intranet.example.com"])
        model.removeHost("intranet.example.com")
        XCTAssertEqual(model.draft.denyHosts, [])
    }

    func testSkipMarksSkippedAndMovesOn() async {
        let (model, cli) = make()
        await model.open()
        model.toggle(.linear)
        await model.next()
        await model.skip()
        XCTAssertEqual(model.current, .denyList)
        XCTAssertEqual(model.marks()[.vendor(.linear)], .skipped)
        XCTAssertEqual(Model.railWord(.skipped), "Skipped")
        XCTAssertEqual(savedDrafts(cli).last?["skipped"] as? [String], ["linear"])
        // A skipped step reopens from the rail.
        model.goTo(.vendor(.linear))
        XCTAssertEqual(model.current, .vendor(.linear))
        XCTAssertFalse(model.isSkipped(.linear))
        // A step not reached yet is not clickable.
        model.goTo(.publish)
        XCTAssertEqual(model.current, .vendor(.linear))
    }

    func testConfluenceRefusedShowsOff() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [atlassianOK.replacingOccurrences(of: #""confluence":true"#,
                                                                                    with: #""confluence":false"#)])
        await model.check(.atlassian)
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertTrue(model.publishSummary[2].contains("· Confluence off ·"))
    }

    func testForcedCompanySaysTheProfileWins() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [atlassianOK.replacingOccurrences(of: #""result":"ok""#,
                                                                                    with: #""result":"forced""#)])
        await model.check(.atlassian)
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertEqual(model.checkLine(.atlassian), "Your organization sets Acme's apps on this Mac; what you set up here is "
            + "used once the profile is removed.")
    }

    func testCheckNotRecordedIsNotChecked() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [#"{"result":"ok","slug":"acme","email":"alice@example.com","#
            + #""checked":false,"draft_error":"disk full"}"#])
        await model.check(.atlassian)
        XCTAssertFalse(model.isChecked(.atlassian), "Publish would refuse a step Go did not mark")
        XCTAssertEqual(model.checkLine(.atlassian), "The sign-in worked, but Watchtower could not record the check in this "
            + "setup: disk full. Your account stays connected; check again.")
        XCTAssertEqual(model.connectedAs[.atlassian], "alice@example.com")
        XCTAssertEqual(model.publishBlockedReason, Model.publishWaitsAtlassian)
    }

    func testStaleCheckResultIsDropped() async {
        let draft = #"{"company":"Acme","services":["microsoft"],"step":"microsoft","slack":{},"#
            + #""microsoft":{"client_id":"4b1e0c9d-0000-4f00-a000-00000000077a","tenant_id":"0000-acme"}}"#
        let (model, cli) = await resume(draft)
        cli.hold(["company", "check", "microsoft"])
        let check = Task { await model.check(.microsoft) }
        await cli.waitFor(["company", "check", "microsoft"])
        model.setField(.microsoft, .tenantID, "1111-acme")
        cli.release(["company", "check", "microsoft"], [#"{"result":"admin_consent","admin_consent_url":"u"}"#])
        await check.value
        XCTAssertNil(model.checks[.microsoft], "the answer was about the old tenant")
        XCTAssertFalse(model.draft.microsoftWaiting)
        XCTAssertEqual(model.current, .vendor(.microsoft))
        XCTAssertEqual(model.primary.title, "Continue")
        // A service dropped while its check ran stays dropped.
        let (dropped, droppedCLI) = await resume(atlassianDraft)
        droppedCLI.hold(["company", "check", "atlassian"])
        let late = Task { await dropped.check(.atlassian) }
        await droppedCLI.waitFor(["company", "check", "atlassian"])
        dropped.toggle(.atlassian)
        dropped.confirmDrop(.atlassian)
        droppedCLI.release(["company", "check", "atlassian"], [atlassianOK])
        await late.value
        XCTAssertNil(dropped.checks[.atlassian])
        XCTAssertFalse(dropped.isChecked(.atlassian))
        XCTAssertEqual(dropped.ticked, [])
    }

    func testResumeWhileWaitingForConsentShowsTheLink() async {
        let draft = #"{"company":"Acme","services":["microsoft"],"step":"microsoft","slack":{},"microsoft_waiting":true,"#
            + #""microsoft":{"client_id":"4b1e","tenant_id":"0000-acme"}}"#
        let (model, _) = await resume(draft)
        XCTAssertEqual(model.checks[.microsoft], .adminConsent(url: "https://login.microsoftonline.com/0000-acme/adminconsent?client_id=4b1e"))
        XCTAssertEqual(model.primary, .init(title: "Continue", enabled: true))
    }

    func testPublishDraftNotDeletedIsSaid() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        cli.on(["company", "publish"], [#"{"result":"ok","slug":"acme","link":"l","code":"c","draft_error":"busy"}"#])
        await model.next()
        XCTAssertTrue(model.isPublished)
        XCTAssertEqual(model.publishDraftLeft, "Published. The setup's draft could not be deleted from this Mac (busy); "
            + "Discard setup removes it.")
    }

    func testPublishThenLeaveWritesNoDraft() async {
        let (model, cli) = await publishReady()
        model.slackToken = token
        cli.on(["company", "publish"], [#"{"result":"ok","slug":"acme","link":"l","code":"c"}"#])
        await model.next()
        let saves = cli.calls(["company", "draft", "save"]).count
        await model.leave()
        XCTAssertEqual(cli.calls(["company", "draft", "save"]).count, saves, "Go deleted the draft; it stays deleted")
        XCTAssertNil(model.resumeLine)
        model.finish()
        XCTAssertEqual(model.current, .services)
        XCTAssertEqual(model.publishState, .ready)
    }

    func testCheckThatDiesSaysSo() async {
        let (model, cli) = await resume(atlassianDraft)
        cli.on(["company", "check", "atlassian"], [], exit: 1)
        await model.check(.atlassian)
        XCTAssertEqual(model.checkLine(.atlassian), "The check stopped before it answered. Nothing was saved; try again.")
        XCTAssertFalse(model.isChecked(.atlassian))
    }

    // MARK: - Strings

    func testStringsEqualMockCopy() {
        XCTAssertEqual(Model.wizardTitle, "Set up Watchtower for your company")
        XCTAssertEqual(Model.wizardIntro, "One pass for every service your company uses. Each step can be skipped; Watchtower "
            + "keeps your progress, so you can leave this page and come back.")
        XCTAssertEqual([Model.railWord(.done), Model.railWord(.reused), Model.railWord(.skipped), Model.railWord(.waiting)],
                       ["Done", "Reused", "Skipped", "Waiting"])
        XCTAssertNil(Model.railWord(.notStarted))
        XCTAssertEqual(Model.changeServices, "Change services")
        XCTAssertEqual(Model.skipStep, "Skip this step")
        XCTAssertEqual(Model.draftUnreadableTitle, "Your unfinished setup could not be read — start again")
        XCTAssertEqual(Model.showInFinder, "Show file in Finder")
        XCTAssertEqual(Model.discardSetup, "Discard setup")
        XCTAssertEqual(Model.createNew, "Create new")
        XCTAssertEqual(Model.alreadyHaveOne, "We already have one")
        XCTAssertEqual(Model.createNewDetail, "Watchtower walks you through creating it.")
        XCTAssertEqual(Model.alreadyHaveDetail, "Paste what identifies it; Watchtower checks it before going on.")
        XCTAssertEqual(Model.useSelected, "Use the selected client")
        XCTAssertEqual(Model.reuseSecretBody, "This Mac knows the client id but not its secret. Open the client in Cloud "
            + "Console, copy its secret and paste it here.")
        XCTAssertEqual(Model.slackProgressCaption, "You can leave this page: the setup resumes at this step, and the app is "
            + "never created twice.")
        XCTAssertEqual(Model.manifestDiffBody, "Watchtower will make these changes to the app. Nothing else in it changes.")
        XCTAssertEqual([Model.readingApp("A0ACME"), Model.comparingApp], ["Reading app A0ACME's settings",
                                                                          "Comparing them with Watchtower's"])
        XCTAssertEqual(Model.checkingGoogle, "Finish in your browser: sign in to Google with this client. Your sign-in "
            + "checks the client and connects your own Google account.")
        XCTAssertEqual(Model.atlassianSigninWait, "Finish in your browser: sign in to Atlassian with this app. Your sign-in "
            + "checks the client id, the secret and the callback URLs, and connects your own Atlassian account.")
        XCTAssertEqual(Model.confirmChecks.count, 3)
        XCTAssertEqual(Model.consentTitle, "Your IT admin must approve Watchtower in Microsoft 365")
        XCTAssertEqual(Model.publishCaption, "Writes the connect link and code to the About page of Watchtower's app in Slack.")
        XCTAssertEqual(Model.publishNeedsTokenLine, "Paste a configuration token to write the link to the Slack page. It is "
            + "used once and never stored.")
        XCTAssertTrue(Model.publishedBody.hasSuffix("Connect this Mac adds the rest."))
        XCTAssertTrue(Model.publishedNoSlack.hasPrefix("Slack was skipped, so no page carries the link."))
        XCTAssertEqual(Model.checkingLine(.microsoft), "Checking the client with Microsoft…")
        XCTAssertEqual(Model.checkingLine(.linear), "Checking the client with Linear…")
        XCTAssertEqual(Model.networkLine(.microsoft, "the request timed out"),
                       "Could not reach Microsoft: the request timed out. Nothing was saved.")
        XCTAssertEqual(Model.short("4b1e0c9d-0000-4f00-a000-00000000077a"), "4b1e…77a")
        // The Slack token form keeps Slack spec §3.2's texts (SlackAppSetupModel's).
        XCTAssertEqual(Model.slackTokenStep1, SlackAppSetupModel.step1Title)
        XCTAssertEqual(Model.slackTokenHelp, SlackAppSetupModel.step1Help)
        XCTAssertEqual(Model.openTokenPage, SlackAppSetupModel.openTokenPage)
        XCTAssertEqual(Model.slackTokenStep2, SlackAppSetupModel.step2Title)
        XCTAssertEqual(Model.tokenPlaceholder, SlackAppSetupModel.tokenPlaceholder)
        XCTAssertEqual(Model.tokenNote, SlackAppSetupModel.tokenNote)
        XCTAssertEqual(Model.slackTokenHelp, SlackAppSetupModel.step1Help)
    }
}
