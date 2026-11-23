import Foundation
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The company setup and own-Google-project connect drivers (agent connect
/// spec §5.4) over the wizard's and the page's own models, with scripted
/// CLIs: no process, no real time.
@MainActor
final class CompanyConnectDriverTests: XCTestCase {
    private typealias Driver = CompanyConnectDriver
    private let token = "xoxe.xoxp-1-sample-token"
    private let acmeSetup = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","client_id":"1111.2222","#
        + #""connected":false,"link_written":false,"install_requested":false,"stage":"link_missing"}]}"#
    private let bothSecrets = #"{"company":"Acme","services":["google","atlassian"],"step":"google","#
        + #""started_at":"2026-11-17T09:00:00Z","slack":{},"google":{"client_id":"1234-abcd.apps.googleusercontent.com","#
        + #""client_secret":"google-sample-secret"},"atlassian":{"client_id":"9f3a8d0e4b7c21","#
        + #""client_secret":"atlassian-sample-secret","site":"https://acme.atlassian.net","confluence":true}}"#
    private let publishDraft = #"{"company":"Acme","slug":"acme","services":["slack","atlassian"],"#
        + #""step":"publish","slack":{"app_id":"A0ACME"},"atlassian":{"client_id":"9f3a8d0e4b7c21","#
        + #""client_secret":"sample-secret","site":"https://acme.atlassian.net","confluence":true}}"#

    private func make(_ cli: CompanyScriptedCLI = CompanyScriptedCLI()) -> (Driver, CompanySetupWizardModel) {
        let wizard = CompanySetupWizardModel(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard))
        return (Driver(wizard: wizard), wizard)
    }

    /// A driver over a stored draft.
    private func resume(_ draft: String, checked: [String] = [], cli: CompanyScriptedCLI = CompanyScriptedCLI())
        async -> (Driver, CompanySetupWizardModel) {
        let list = checked.map { "\"\($0)\"" }.joined(separator: ",")
        cli.on(["company", "draft", "show"], [#"{"state":"ok","draft":"# + draft + #","bad_file":"","checked_vendors":[\#(list)]}"#])
        let (driver, wizard) = make(cli)
        _ = await driver.status()
        return (driver, wizard)
    }

    private func savedDrafts(_ cli: CompanyScriptedCLI) -> [[String: Any]] {
        cli.calls(["company", "draft", "save"]).compactMap {
            $0.stdin.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static func error<T>(_ result: Result<T, ConnectDriverError>) -> ConnectDriverError? {
        if case let .failure(error) = result { return error }
        return nil
    }

    private static func text(_ data: Data) -> String { String(bytes: data, encoding: .utf8) ?? "" }

    private static func text(_ result: Result<Data, ConnectDriverError>) -> String {
        switch result {
        case let .success(data): text(data)
        case let .failure(error): "error:\(error)"
        }
    }

    // MARK: - The draft

    func testDraftViewNeverCarriesSecrets() async throws {
        let (driver, _) = await resume(bothSecrets)
        let view = try await driver.draftView().get()
        let text = Self.text(view)
        XCTAssertFalse(text.contains("google-sample-secret"))
        XCTAssertFalse(text.contains("atlassian-sample-secret"))
        XCTAssertFalse(text.contains("client_secret\""), "only client_secret_set")
        let draft = try JSONDecoder().decode(ConnectCompanyDraft.self, from: view)
        XCTAssertEqual(draft.company, "Acme")
        XCTAssertEqual(draft.vendors["google"]?.clientSecretSet, true)
        XCTAssertEqual(draft.vendors["google"]?.clientID, "1234-abcd.apps.googleusercontent.com")
        XCTAssertEqual(draft.vendors["atlassian"]?.clientSecretSet, true)
        XCTAssertEqual(draft.vendors["atlassian"]?.site, "https://acme.atlassian.net")
        XCTAssertEqual(Set(draft.vendors.keys), ["google", "atlassian"])
    }

    func testClientSecretSavedToDraftNotReturned() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        let answer = await driver.submitSecret(kind: "google_client_secret", value: " google-new-secret\n")
        XCTAssertEqual(Self.text(answer), #"{"result":"saved","vendor":"google"}"#)
        XCTAssertEqual(wizard.draft.google?.clientSecret, "google-new-secret")
        XCTAssertEqual(wizard.ticked, [.google], "a secret for a service means the company uses it")
        let saved = savedDrafts(cli).last
        XCTAssertEqual((saved?["google"] as? [String: Any])?["client_secret"] as? String, "google-new-secret",
                       "the draft holds it (Go's 0600 file), on stdin")
        XCTAssertFalse(cli.calls(["company", "draft", "save"]).contains { $0.args.contains { $0.contains("google-new-secret") } })

        _ = await driver.submitSecret(kind: "atlassian_client_secret", value: "atlassian-new-secret")
        XCTAssertEqual(wizard.draft.atlassian?.clientSecret, "atlassian-new-secret")
        let read = await driver.draftView()
        XCTAssertFalse(Self.text(read).contains("new-secret"))

        let unknown = await driver.submitSecret(kind: "imap_password", value: "x")
        XCTAssertEqual(unknown, .failure(.badArgs("kind imap_password is not a company secret")))
    }

    func testWizardAndPanelShareOneState() async throws {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        let saved = await driver.saveDraft(vendor: "microsoft", fields: [
            "company": "Acme", "services": "microsoft,linear", "client_id": "ms-client", "tenant_id": "acme-tenant"
        ])
        XCTAssertNil(Self.error(saved))
        // The sheet reads the same model instance.
        XCTAssertEqual(wizard.ticked, [.linear, .microsoft])
        XCTAssertEqual(wizard.draft.microsoft?.clientID, "ms-client")
        XCTAssertEqual(wizard.draft.microsoft?.tenantID, "acme-tenant")
        XCTAssertEqual(wizard.publishName, "Acme")
        XCTAssertEqual((savedDrafts(cli).last?["microsoft"] as? [String: Any])?["tenant_id"] as? String, "acme-tenant")

        // A field typed on the sheet shows in the panel's read.
        wizard.setField(.linear, .clientID, "lin_client_1")
        let draft = try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        XCTAssertEqual(draft.vendors["linear"]?.clientID, "lin_client_1")
        XCTAssertEqual(draft.company, "Acme")
    }

    func testDraftSaveTakesDenyHostsAndRefusesUnknownKeys() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        let saved = await driver.saveDraft(vendor: "slack", fields: ["deny_hosts": "intranet.example.com, Wiki.Example.com"])
        XCTAssertNil(Self.error(saved))
        XCTAssertEqual(wizard.draft.denyHosts, ["intranet.example.com", "wiki.example.com"])
        _ = await driver.saveDraft(vendor: "slack", fields: ["deny_hosts": "wiki.example.com"])
        XCTAssertEqual(wizard.draft.denyHosts, ["wiki.example.com"], "the list becomes what the agent saved")
        XCTAssertEqual(savedDrafts(cli).last?["deny_hosts"] as? [String], ["wiki.example.com"])

        let bad = await driver.saveDraft(vendor: "slack", fields: ["deny_hosts": "https://intranet.example.com/x"])
        XCTAssertEqual(Self.error(bad), .badArgs(CompanySetupWizardModel.denyInvalid))
        XCTAssertEqual(wizard.draft.denyHosts, ["wiki.example.com"], "a refused save changes nothing")
        let secret = await driver.saveDraft(vendor: "google", fields: ["client_secret": "x"])
        XCTAssertEqual(Self.error(secret), .badArgs("client_secret is not a google draft field (client_id, company, deny_hosts, services)"))
        let service = await driver.saveDraft(vendor: "google", fields: ["services": "google,dropbox"])
        XCTAssertEqual(Self.error(service), .badArgs("dropbox is not a service (slack, google, atlassian, linear, microsoft)"))

        // Dropping a service that holds entries is the customer's call on the page.
        _ = await driver.saveDraft(vendor: "linear", fields: ["client_id": "lin_client_1"])
        let drop = await driver.saveDraft(vendor: "linear", fields: ["services": ""])
        XCTAssertEqual(Self.error(drop), .failed("Linear holds entries in the draft; the customer drops it on the setup wizard's "
            + "Services step"))
        XCTAssertEqual(wizard.ticked, [.linear])
    }

    func testAtlassianSiteAndConfluence() async {
        let (driver, wizard) = make()
        let saved = await driver.saveDraft(vendor: "atlassian", fields: [
            "client_id": "9f3a8d0e4b7c21", "site": "acme.atlassian.net", "confluence": "false"
        ])
        XCTAssertNil(Self.error(saved))
        XCTAssertEqual(wizard.draft.atlassian?.site, "https://acme.atlassian.net")
        XCTAssertEqual(wizard.draft.atlassian?.confluence, false)
        let bad = await driver.saveDraft(vendor: "atlassian", fields: ["confluence": "maybe"])
        XCTAssertEqual(Self.error(bad), .badArgs("confluence is true or false"))
    }

    // MARK: - Slack step (F3 relaxed)

    func testSlackTokenCreatesTheApp() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        cli.on(["slack", "app", "create"], [#"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
            + #""client_id":"1111.2222","link_written":false}"#])
        cli.setups = acmeSetup
        let answer = await driver.submitSecret(kind: "slack_config_token", value: token)
        XCTAssertEqual(Self.text(answer), #"{"app_id":"A0ACME","result":"ok"}"#)
        XCTAssertNil(driver.secretConfirm(kind: "slack_config_token"), "a new app needs no update card")
        XCTAssertTrue(wizard.slackAppReady)
        XCTAssertEqual(wizard.slackToken, "", "the step's token is dropped once it ends")
        let create = cli.calls(["slack", "app", "create"]).first
        XCTAssertEqual(create?.input, token + "\n", "the token on stdin only")
        XCTAssertFalse(create?.args.contains(token) ?? true)
        let draft = try? JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        XCTAssertEqual(draft?.vendors["slack"]?.clientID, "1111.2222", "the Client ID comes from the setup record")
    }

    private let confirmApp = #"{"result":"confirm_app","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
        + #""app_name":"Watchtower","client_id":"1111.2222","changes":{"add_scopes":["reactions:read"],"enable_pkce":true}}"#

    /// `app_id` takes the id (any case) or a link to the app; `settings_link`
    /// is its older name, and both at once are refused.
    func testSlackAppIDField() async {
        let (driver, wizard) = make()
        let both = await driver.saveDraft(vendor: "slack", fields: ["app_id": "A0ACME", "settings_link": "A0ACME"])
        XCTAssertEqual(Self.error(both), .badArgs("app_id and settings_link both name the Slack app; give app_id only"))
        let bad = await driver.saveDraft(vendor: "slack", fields: ["app_id": "https://acme.slack.com/apps"])
        XCTAssertEqual(Self.error(bad), .badArgs(CompanySetupWizardModel.slackAppIDInvalidLine))
        let saved = await driver.saveDraft(vendor: "slack", fields: ["app_id": "https://app.slack.com/app/a0acme"])
        XCTAssertNil(Self.error(saved))
        XCTAssertEqual(wizard.slackReuse?.appID, "A0ACME")
        XCTAssertEqual(wizard.slackAppIDInput, "A0ACME", "the field shows the id")
    }

    func testSavedLinkUpdatesTheAppAfterConfirm() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        let saved = await driver.saveDraft(vendor: "slack", fields: ["settings_link": "https://api.slack.com/apps/A0ACME"])
        XCTAssertNil(Self.error(saved))
        XCTAssertEqual(wizard.current, .vendor(.slack), "the wizard's Slack-step handoff")
        XCTAssertEqual(wizard.slackReuse?.appID, "A0ACME")

        cli.on(["slack", "app", "adopt"], [confirmApp])
        let read = await driver.submitSecret(kind: "slack_config_token", value: token)
        XCTAssertEqual(Self.text(read), #"{"result":"confirm_update"}"#)
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).first?.args.last, "--dry-run", "the token first only reads the app")
        XCTAssertEqual(driver.secretConfirm(kind: "slack_config_token"),
                       .slackUpdate(changes: ["Add scopes: reactions:read", "Turn on PKCE sign-in"], pkce: true))

        cli.setups = acmeSetup
        cli.on(["slack", "app", "adopt"], [#"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
            + #""client_id":"1111.2222","link_written":true}"#])
        let updated = await driver.answerSecretConfirm(kind: "slack_config_token", yes: true)
        XCTAssertEqual(Self.text(updated), #"{"app_id":"A0ACME","result":"ok"}"#)
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).last?.args.contains("--dry-run"), false)
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).last?.args.contains("--confirm-app-id"), true)
        XCTAssertTrue(wizard.slackAppReady)
        XCTAssertNil(driver.secretConfirm(kind: "slack_config_token"))
        XCTAssertEqual(wizard.slackToken, "")
    }

    func testDeclinedUpdateChangesNothing() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        _ = await driver.saveDraft(vendor: "slack", fields: ["settings_link": "https://api.slack.com/apps/A0ACME"])
        cli.on(["slack", "app", "adopt"], [confirmApp])
        _ = await driver.submitSecret(kind: "slack_config_token", value: token)
        let declined = await driver.answerSecretConfirm(kind: "slack_config_token", yes: false)
        XCTAssertEqual(Self.text(declined), #"{"result":"declined"}"#)
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).count, 1, "no update ran")
        XCTAssertNil(wizard.slackDiff)
        XCTAssertEqual(wizard.slackToken, "")
        XCTAssertFalse(wizard.slackAppReady)
        let late = await driver.answerSecretConfirm(kind: "slack_config_token", yes: true)
        XCTAssertEqual(late, .failure(.failed(Driver.updateGone)))
    }

    /// The update card was up while the customer moved the wizard: yes
    /// updates nothing and never presses another step's action.
    func testApprovalAfterWizardMovedRunsNothing() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        _ = await driver.saveDraft(vendor: "slack", fields: ["settings_link": "https://api.slack.com/apps/A0ACME"])
        cli.on(["slack", "app", "adopt"], [confirmApp])
        _ = await driver.submitSecret(kind: "slack_config_token", value: token)
        wizard.goTo(.services)
        let calls = cli.calls.count
        let answer = await driver.answerSecretConfirm(kind: "slack_config_token", yes: true)
        XCTAssertEqual(answer, .failure(.failed(Driver.updateGone)))
        XCTAssertEqual(cli.calls.count, calls, "no adopt, no Publish, no save")
        XCTAssertEqual(wizard.current, .services)
        XCTAssertEqual(wizard.slackToken, "", "the token goes")
        XCTAssertNil(driver.secretConfirm(kind: "slack_config_token"))
    }

    func testDroppedCardClearsTokenAndDiff() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        _ = await driver.saveDraft(vendor: "slack", fields: ["settings_link": "https://api.slack.com/apps/A0ACME"])
        cli.on(["slack", "app", "adopt"], [confirmApp])
        _ = await driver.submitSecret(kind: "slack_config_token", value: token)
        XCTAssertEqual(wizard.slackToken, token)
        XCTAssertNotNil(wizard.slackDiff)
        driver.secretConfirmDropped(kind: "slack_config_token")
        XCTAssertEqual(wizard.slackToken, "")
        XCTAssertNil(wizard.slackDiff)
        XCTAssertNil(driver.secretConfirm(kind: "slack_config_token"))
        XCTAssertEqual(cli.calls(["slack", "app", "adopt"]).count, 1)
    }

    /// A token card the customer never used goes (run end, timeout): what
    /// the customer has on the page (their token, their diff) stays.
    func testDroppedUnusedCardLeavesThePageAlone() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        _ = await driver.status()
        wizard.toggle(.slack)
        await wizard.next()
        wizard.alreadyHaveOne()
        wizard.setField(.slack, .slackAppID, "https://api.slack.com/apps/A0ACME")
        await wizard.next()
        wizard.slackToken = token
        cli.on(["slack", "app", "adopt"], [confirmApp])
        await wizard.next()
        await untilObserved { wizard.slackDiff != nil }
        driver.secretConfirmDropped(kind: "slack_config_token")
        XCTAssertEqual(wizard.slackToken, token, "the customer's token stays")
        XCTAssertNotNil(wizard.slackDiff, "the customer's diff stays")
    }

    func testUnreadableDraftIsNotAFreshOne() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [#"{"state":"unreadable","draft":null,"bad_file":"draft.json.bad-x","checked_vendors":[]}"#])
        let (driver, wizard) = make(cli)
        let read = await driver.draftView()
        XCTAssertEqual(wizard.load, .ready, "the page opens on its unreadable notice")
        let expected = "\(CompanySetupWizardModel.draftUnreadableTitle). "
            + CompanySetupWizardModel.draftUnreadableBody(file: "draft.json.bad-x")
        XCTAssertEqual(Self.error(read), .failed(expected))
    }

    func testVendorValuesWithServicesLeavingItOutAreRefused() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        let save = await driver.saveDraft(vendor: "linear", fields: ["client_id": "lin_client_1", "services": "google"])
        XCTAssertEqual(Self.error(save), .badArgs("linear values come with a services list that leaves linear out"))
        XCTAssertEqual(wizard.ticked, [], "nothing landed")
        XCTAssertNil(wizard.draft.linear)
        XCTAssertTrue(cli.calls(["company", "draft", "save"]).isEmpty)
        let both = await driver.saveDraft(vendor: "linear", fields: ["client_id": "lin_client_1", "services": "google,linear"])
        XCTAssertNil(Self.error(both))
        XCTAssertEqual(wizard.ticked, [.google, .linear])
    }

    func testReadAfterUnreadableDraftReplacedSucceeds() async throws {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [#"{"state":"unreadable","draft":null,"bad_file":"draft.json.bad-x","checked_vendors":[]}"#])
        let (driver, wizard) = make(cli)
        let before = await driver.draftView()
        XCTAssertNotNil(Self.error(before))
        _ = await driver.saveDraft(vendor: "linear", fields: ["company": "Acme", "client_id": "lin_client_1"])
        XCTAssertNotNil(wizard.draftUnreadable, "the page keeps its notice: the set-aside file stays until Discard or Publish")
        let read = try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        XCTAssertEqual(read.company, "Acme")
        XCTAssertEqual(read.vendors["linear"]?.clientID, "lin_client_1")
    }

    func testLinkOfAnotherAppWhileOneIsReadyIsRefused() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let (driver, wizard) = await resume(publishDraft, checked: ["atlassian"], cli: cli)
        XCTAssertTrue(wizard.slackAppReady)
        let other = await driver.saveDraft(vendor: "slack", fields: [
            "settings_link": "https://api.slack.com/apps/A0OTHER", "company": "Other", "deny_hosts": "a.example.com"
        ])
        XCTAssertEqual(Self.error(other), .failed(Driver.otherSlackApp("A0ACME")))
        XCTAssertEqual(wizard.draft.slack.appID, "A0ACME")
        XCTAssertEqual(wizard.current, .publish, "the page did not move")
        XCTAssertEqual(wizard.publishName, "Acme", "nothing else in the refused save landed")
        let same = await driver.saveDraft(vendor: "slack", fields: ["settings_link": "https://api.slack.com/apps/A0ACME"])
        XCTAssertNil(Self.error(same))
    }

    func testCompanyNameKeptInTheDraft() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        _ = await driver.saveDraft(vendor: "linear", fields: ["company": "Acme"])
        XCTAssertEqual(wizard.draft.company, "Acme")
        XCTAssertEqual(savedDrafts(cli).last?["company"] as? String, "Acme", "a restart keeps it")

        // Once a check stored the company, its name is fixed: the new one is Publish's display name only.
        let (stored, storedWizard) = await resume(publishDraft)
        _ = await stored.saveDraft(vendor: "slack", fields: ["company": "Acme Corp"])
        XCTAssertEqual(storedWizard.draft.company, "Acme")
        XCTAssertEqual(storedWizard.publishName, "Acme Corp")
    }

    func testUnreadableDraftIsAnError() async {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [], exit: 1)
        let (driver, _) = make(cli)
        let read = await driver.draftView()
        XCTAssertEqual(Self.error(read), .failed(CompanySetupWizardModel.draftReadFailed))
    }

    func testRefusedSaveChangesNothing() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = await resume(bothSecrets, cli: cli)
        cli.hold(["company", "check", "google"])
        let check = Task { await driver.check(vendor: "google") }
        await cli.waitFor(["company", "check", "google"])
        let saves = cli.calls(["company", "draft", "save"]).count
        let busy = await driver.saveDraft(vendor: "google", fields: ["company": "Other", "deny_hosts": "a.example.com",
                                                                     "client_id": "new-client"])
        XCTAssertEqual(Self.error(busy), .busy)
        XCTAssertEqual(wizard.publishName, "Acme")
        XCTAssertEqual(wizard.draft.denyHosts, [])
        XCTAssertEqual(cli.calls(["company", "draft", "save"]).count, saves)
        cli.release(["company", "check", "google"], [#"{"result":"network","message":"offline"}"#])
        _ = await check.value
    }

    func testDraftReadCarriesTenantChecksAndSlackReady() async throws {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let draft = #"{"company":"Acme","services":["slack","linear","microsoft"],"step":"publish","#
            + #""slack":{"app_id":"A0ACME"},"microsoft":{"client_id":"ms-client","tenant_id":"acme-tenant"},"#
            + #""linear":{"client_id":"lin_client_1"},"skipped":["linear"]}"#
        let (driver, _) = await resume(draft, checked: ["microsoft"], cli: cli)
        let read = try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        XCTAssertEqual(read.vendors["microsoft"]?.tenantID, "acme-tenant")
        XCTAssertEqual(read.vendors["microsoft"]?.checked, true)
        XCTAssertEqual(read.vendors["linear"]?.skipped, true)
        XCTAssertEqual(read.vendors["slack"]?.ready, true)
        XCTAssertNil(read.vendors["microsoft"]?.ready, "ready is Slack's alone")
        XCTAssertEqual(read.services, ["slack", "linear", "microsoft"], "the ticked services, in the wizard's order")
    }

    /// What the customer already chose in the wizard reaches the agent's
    /// read, so the playbook does not ask it again (#1146).
    func testDraftReadCarriesTheWizardsChoices() async throws {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        _ = await driver.status()
        wizard.toggle(.google)
        wizard.toggle(.slack)
        wizard.setCompanyName("Acme")
        func read() async throws -> ConnectCompanyDraft {
            try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        }
        var draft = try await read()
        XCTAssertEqual(draft.services, [], "ticks on the Services step are not settled until it is continued")
        XCTAssertEqual(draft.company, "Acme")

        await wizard.next()  // past Services: the Slack step's first screen, still no choice
        draft = try await read()
        XCTAssertEqual(draft.services, ["slack", "google"])
        XCTAssertNil(draft.vendors["slack"]?.app, "no choice on the Slack step's first screen")

        wizard.createNew()
        draft = try await read()
        XCTAssertEqual(draft.vendors["slack"]?.app, "new")
        XCTAssertNil(draft.vendors["google"]?.app, "app is Slack's alone")

        wizard.alreadyHaveOne()
        draft = try await read()
        XCTAssertEqual(draft.vendors["slack"]?.app, "existing")

        // An App ID entered, then Back from the run's problem: the choice is open again.
        wizard.setField(.slack, .slackAppID, "A0ACME")
        await wizard.next()
        draft = try await read()
        XCTAssertEqual(draft.vendors["slack"]?.app, "existing")
        wizard.slackToken = token
        cli.on(["slack", "app", "adopt"], [#"{"result":"not_collaborator","team_id":"T0ACME","team_name":"acme"}"#])
        await wizard.next()
        await untilObserved { wizard.slackProblem != nil }
        wizard.back()
        XCTAssertEqual(wizard.current, .vendor(.slack), "back to the step's first screen")
        draft = try await read()
        XCTAssertNil(draft.vendors["slack"]?.app, "Back leaves no choice behind")
    }

    /// A found app picked on the Slack step is an existing app.
    func testPickedFoundSlackAppIsExisting() async throws {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"slack","client_id":"1111.2222","app_id":"A0ACME","#
            + #""label":"Watchtower · A0ACME","source":"account","source_label":"Slack app — your connected account acme"}]}"#])
        let (driver, wizard) = make(cli)
        await wizard.open()
        await wizard.next()
        XCTAssertEqual(wizard.phase(.slack), .found)
        var draft = try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        XCTAssertNil(draft.vendors["slack"]?.app, "Found is the step's first screen")
        await wizard.next()  // Use Watchtower
        draft = try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        XCTAssertEqual(draft.vendors["slack"]?.app, "existing")
    }

    /// Discovery pre-ticks the vendors it found; the read says none until
    /// the customer confirms the Services step, so the playbook asks.
    func testDiscoveryPreTicksAreNotTheCustomersServices() async throws {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "discover"], [#"{"candidates":[{"vendor":"linear","client_id":"lin","label":"lin","#
            + #""source":"account","source_label":"Linear"}]}"#])
        let (driver, wizard) = make(cli)
        await wizard.open()
        XCTAssertEqual(wizard.ticked, [.linear], "discovery pre-ticked Linear")
        func read() async throws -> ConnectCompanyDraft {
            try JSONDecoder().decode(ConnectCompanyDraft.self, from: await driver.draftView().get())
        }
        var draft = try await read()
        XCTAssertEqual(draft.services, [], "opened on Services, never continued")
        XCTAssertEqual(draft.vendors, [:])

        await wizard.next()
        draft = try await read()
        XCTAssertEqual(draft.services, ["linear"], "continued: the ticks are the customer's")
        XCTAssertNotNil(draft.vendors["linear"])

        // The agent saving a list settles it too.
        let (other, otherWizard) = make(cli)
        await otherWizard.open()
        _ = try await other.saveDraft(vendor: "google", fields: ["services": "google"]).get()
        draft = try JSONDecoder().decode(ConnectCompanyDraft.self, from: await other.draftView().get())
        XCTAssertEqual(draft.services, ["google"])
    }

    func testSlackProblemIsTheWizardsLine() async {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = make(cli)
        cli.on(["slack", "app", "create"], [#"{"result":"bad_token","team_id":"","team_name":""}"#])
        let answer = await driver.submitSecret(kind: "slack_config_token", value: token)
        guard case let .failure(.failed(line)) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(line, wizard.slackProblem)
        XCTAssertEqual(wizard.slackToken, "")
    }

    // MARK: - Checks and Publish

    func testReplaceNeedsConfirm() async throws {
        let cli = CompanyScriptedCLI()
        let (driver, wizard) = await resume(bothSecrets, cli: cli)
        XCTAssertNil(driver.confirmNeeded(tool: "company_check", options: ["vendor": "atlassian"]), "an ordinary check")
        cli.on(["company", "check", "atlassian"], [#"{"result":"replace_needed","slug":"acme","code":"client_id"}"#])
        let first = await driver.check(vendor: "atlassian")
        XCTAssertEqual(Self.text(first), #"{"result":"replace_needed"}"#)
        XCTAssertFalse(cli.calls(["company", "check"]).first?.args.contains("--replace") ?? true)
        XCTAssertEqual(driver.confirmNeeded(tool: "company_check", options: ["vendor": "atlassian"]), .companyReplace(company: "Acme"))

        // The controller runs it again only after the customer's yes: now with --replace.
        cli.on(["company", "check", "atlassian"], [#"{"result":"ok","slug":"acme","account_id":7,"email":"alice@example.com","#
            + #""site":"https://acme.atlassian.net","checked":true,"confluence":true}"#])
        let second = await driver.check(vendor: "atlassian")
        XCTAssertEqual(Self.text(second), #"{"account":"alice@example.com","result":"ok"}"#)
        XCTAssertEqual(cli.calls(["company", "check", "atlassian"]).last?.args.last, "--replace")
        XCTAssertTrue(wizard.isChecked(.atlassian))
        let shape = try JSONDecoder().decode(ConnectCompanyChecked.self, from: second.get())
        XCTAssertEqual(shape.account, "alice@example.com")
    }

    func testCheckAnswers() async {
        let cli = CompanyScriptedCLI()
        let (driver, _) = make(cli)
        _ = await driver.saveDraft(vendor: "microsoft", fields: ["client_id": "ms-client", "tenant_id": "acme-tenant"])
        cli.on(["company", "check", "microsoft"], [#"{"result":"admin_consent","code":"AADSTS65001","admin_consent_url":"u"}"#])
        let consent = await driver.check(vendor: "microsoft")
        XCTAssertEqual(Self.text(consent), #"{"admin_consent_url":"u","result":"admin_consent"}"#)
        let slack = await driver.check(vendor: "slack")
        XCTAssertEqual(slack, .failure(.badArgs("slack has no check: Google, Atlassian, Linear and Microsoft 365 do")))
        let unused = await driver.check(vendor: "google")
        XCTAssertEqual(unused, .failure(.badArgs("google is not among the company's services")))
    }

    /// The revision the Publish card binds to moves with the name and any
    /// draft value, never with the page the wizard shows.
    func testPublishRevisionFollowsTheValues() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let (driver, wizard) = await resume(publishDraft, checked: ["atlassian"], cli: cli)
        _ = driver.confirmNeeded(tool: "company_publish", options: [:])
        let approved = driver.publishRevision
        wizard.publishName = "Acme Corp"
        XCTAssertNotEqual(driver.publishRevision, approved, "another name is another publish")
        wizard.publishName = "Acme"
        XCTAssertEqual(driver.publishRevision, approved)
        _ = await driver.saveDraft(vendor: "atlassian", fields: ["site": "other.atlassian.net"])
        XCTAssertNotEqual(driver.publishRevision, approved, "an edited draft is another publish")
    }

    /// The revision is a digest: the client secret the draft holds never
    /// sits in the controller's step.
    func testPublishRevisionHoldsNoSecret() async {
        let draft = #"{"company":"Acme","services":["google"],"step":"publish","slack":{},"google":{"client_id":"x","#
            + #""client_secret":"s3cret-client-value"}}"#
        let (driver, _) = await resume(draft)
        let revision = driver.publishRevision
        XCTAssertFalse(revision.contains("s3cret"))
        XCTAssertFalse(revision.contains("Acme"))
        XCTAssertEqual(revision.count, 64)
        XCTAssertTrue(revision.allSatisfy(\.isHexDigit))
    }

    /// A stale approval publishes nothing: checked before the save, and
    /// again once the draft Go publishes is saved.
    func testPublishRefusesAStaleApproval() async {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let (driver, wizard) = await resume(publishDraft, checked: ["atlassian"], cli: cli)
        _ = driver.confirmNeeded(tool: "company_publish", options: [:])
        cli.on(["company", "publish"], [#"{"result":"ok","slug":"acme","link":"l","code":"c"}"#])
        let stale = await driver.publish(token: token, approvedRevision: "0000")
        XCTAssertEqual(stale, .failure(.failed(CompanySetupWizardModel.publishChangedLine)))
        await wizard.publish(token: token) { false }
        XCTAssertEqual(wizard.publishRefusal, CompanySetupWizardModel.publishChangedLine)
        XCTAssertEqual(wizard.publishState, .ready)
        XCTAssertTrue(cli.calls(["company", "publish"]).isEmpty, "nothing reached company publish")
    }

    func testPublishNeedsConfirm() async throws {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let (driver, wizard) = await resume(publishDraft, checked: ["atlassian"], cli: cli)
        XCTAssertEqual(driver.confirmNeeded(tool: "company_publish", options: [:]),
                       .companyPublish(company: "Acme", services: ["Slack", "Atlassian"]))
        XCTAssertTrue(driver.publishNeedsToken, "Slack is part of it: the token card follows the confirm")
        XCTAssertTrue(cli.calls(["company", "publish"]).isEmpty, "the card alone publishes nothing")

        cli.on(["company", "publish"], [#"{"result":"ok","slug":"acme","link":"l","code":"c"}"#])
        let published = await driver.publish(token: token, approvedRevision: driver.publishRevision)
        XCTAssertEqual(Self.text(published), #"{"result":"ok","slug":"acme"}"#)
        XCTAssertEqual(cli.calls(["company", "publish"]).first?.input, #"{"company":"Acme","config_token":"\#(token)"}"#)
        XCTAssertEqual(wizard.current, .publish, "the link and code wait on the wizard's Publish page")
        XCTAssertFalse(Self.text(published).contains("\"l\""), "the link stays on the page")
    }

    func testPublishBlockedSaysWhy() async {
        let draft = #"{"company":"Acme","services":["google"],"step":"publish","slack":{},"google":{"client_id":"x","#
            + #""client_secret":"y"}}"#
        let (driver, _) = await resume(draft)
        XCTAssertNil(driver.confirmNeeded(tool: "company_publish", options: [:]), "no card while Publish cannot run")
        XCTAssertEqual(driver.publishBlockedReason, CompanySetupWizardModel.publishWaits(.google))
    }

    func testPublishWithoutSlackIsNoSlack() async {
        let draft = #"{"company":"Acme","slug":"acme","services":["linear"],"step":"publish","slack":{},"#
            + #""linear":{"client_id":"lin_client_1"}}"#
        let cli = CompanyScriptedCLI()
        let (driver, _) = await resume(draft, cli: cli)
        XCTAssertFalse(driver.publishNeedsToken)
        cli.on(["company", "publish"], [#"{"result":"no_slack","slug":"acme","link":"l","code":"c"}"#])
        let published = await driver.publish(token: "", approvedRevision: driver.publishRevision)
        XCTAssertEqual(Self.text(published), #"{"result":"no_slack","slug":"acme"}"#)
        XCTAssertEqual(cli.calls(["company", "publish"]).first?.input, #"{"company":"Acme"}"#)
    }

    func testOrderIsTheWizards() {
        let (driver, _) = make()
        XCTAssertEqual(driver.order(), [.slack, .google, .atlassian, .linear, .microsoft])
        XCTAssertEqual(driver.secretKinds, ["google_client_secret", "atlassian_client_secret", "slack_config_token"])
    }

    // MARK: - Own Google project

    private static let ownOK = #"{"result":"ok","account_id":4,"email":"bob@example.org"}"#

    private func ownDriver(_ replies: [FakeCLILineStream.Reply] = [], policy: ManagedPolicy = ManagedPolicy())
        -> (OwnGoogleProjectConnectDriver, OwnGoogleProjectModel, FakeCLILineStream) {
        let cli = FakeCLILineStream(replies: replies)
        let model = OwnGoogleProjectModel { cli }
        return (OwnGoogleProjectConnectDriver(model: model) { policy }, model, cli)
    }

    func testOwnGoogleClientNeedsConfirm() async throws {
        let (driver, model, cli) = ownDriver([.init(lines: [Self.ownOK])])
        XCTAssertEqual(driver.confirmNeeded(tool: "connect_start", options: ["own_client": "5678-own"]), .ownGoogleClient(clientID: "5678-own"))
        XCTAssertNil(driver.confirmNeeded(tool: "connect_wait", options: [:]))

        let early = await driver.start(options: ["own_client": "5678-own"])
        XCTAssertEqual(early, .failure(.badArgs("call request_secret with kind google_client_secret before connect_start")))
        let saved = await driver.submitSecret(kind: "google_client_secret", value: "own-secret\n")
        XCTAssertEqual(Self.text(saved), #"{"result":"saved"}"#)
        XCTAssertTrue(cli.invocations.isEmpty, "the secret alone runs nothing")

        let flowID = try await driver.start(options: ["own_client": "5678-own"]).get()
        let outcome = await driver.wait(flowID: flowID)
        XCTAssertEqual(outcome, .connected(account: "bob@example.org"))
        let call = try XCTUnwrap(cli.invocations.first)
        XCTAssertEqual(call.args, OwnGoogleProjectModel.connectArgs(clientID: "5678-own"))
        XCTAssertFalse(call.args.contains { $0.contains("own-secret") }, "the secret never goes in argv")
        XCTAssertEqual(call.stdin.flatMap { String(data: $0, encoding: .utf8) }, "own-secret\n")
        XCTAssertEqual(model.droppedLine, OwnGoogleProjectModel.assistantClientName)

        // An ended flow answers at once; one this driver never knew fails.
        let again = await driver.wait(flowID: flowID)
        XCTAssertEqual(again, .connected(account: "bob@example.org"))
        let unknown = await driver.wait(flowID: "own-google-9")
        XCTAssertEqual(unknown, .failed(reason: OwnGoogleProjectConnectDriver.unknownFlow))
        let status = await driver.status()
        XCTAssertNil(status.flow)
    }

    func testOwnGoogleFailureReadsThePagesLine() async throws {
        let (driver, model, _) = ownDriver([.init(lines: [#"{"result":"rejected","code":"invalid_client","message":"m"}"#])])
        _ = await driver.submitSecret(kind: "google_client_secret", value: "own-secret")
        let flowID = try await driver.start(options: ["own_client": "5678-own"]).get()
        let outcome = await driver.wait(flowID: flowID)
        guard case let .failed(reason) = outcome, case let .failed(line) = model.phase else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason, line)
    }

    func testPolicyRefusesOwnGoogleWhenNotAllowed() async {
        var policy = ManagedPolicy()
        policy.allowOwnGoogleProject = false
        let (driver, model, cli) = ownDriver([.init(lines: [Self.ownOK])], policy: policy)
        model.open()
        XCTAssertFalse(driver.policyAllows())
        let secret = await driver.submitSecret(kind: "google_client_secret", value: "own-secret")
        XCTAssertEqual(Self.error(secret), .policy)
        let start = await driver.start(options: ["own_client": "5678-own"])
        XCTAssertEqual(start, .failure(.policy))
        XCTAssertFalse(model.isOpen, "the policy closes the page")
        XCTAssertFalse(model.hasTypedSecret)
        XCTAssertTrue(cli.invocations.isEmpty)
        let status = await driver.status()
        XCTAssertTrue(status.policyLocked)
    }
}
