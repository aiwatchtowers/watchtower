import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

private typealias Copy = CompanySetupMockCopy
private typealias Model = CompanySetupWizardModel

/// The `company-wizard-*` shots drawn by the production page (Task 22): each
/// scene is a real `CompanySetupWizardModel` walked to its state over a
/// scripted `watchtower` (`CompanyScriptedCLI`, the verbs and JSON the model
/// tests use), then `CompanySetupPage` renders it. A scene starts as a fresh
/// setup in one sitting — so no resume line — unless it is about resuming.
/// Busy states hold their run open; the main run loop is turned (no clock)
/// until the state has landed. Sample data only (`Acme`, `acme`,
/// `example.com`, made-up ids).
@MainActor
enum CompanyWizardLive {
    /// The page for a scene name of `CompanyWizardScenes` (plus `extraScenes`).
    static func page(_ name: String, narrow: Bool = false) -> AnyView {
        AnyView(CompanySetupPage(model: model(name), actions: CompanySetupActions(connectThisMac: connectThisMac), layout: narrow ? .narrow : .wide)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    /// **Connect this Mac** is drawn (its flow is Task 23's); the shot never presses it.
    private static func connectThisMac() {}

    /// The page's own states the mockups have no frame for: the draft being
    /// read, and a draft that could not be read (Try again).
    static let extraScenes = ["loading", "readFailed"]

    // MARK: Sample data

    private static let token = "xoxe.xoxp-1-sample-token"
    private static let started = ISO8601DateFormatter().date(from: "2026-11-17T09:00:00Z") ?? Date()
    private static let acmeSetup = #"{"setups":[{"team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
        + #""client_id":"1111.2222","connected":true,"link_written":false,"install_requested":false,"#
        + #""stage":"link_missing"}]}"#
    private static let noSetups = #"{"setups":[]}"#
    private static let slackCandidate = #"{"vendor":"slack","client_id":"1111.2222","app_id":"A0ACME","#
        + #""label":"Watchtower · A0ACME","source":"account","source_label":"Slack app — your connected account acme"}"#
    private static let atlassianCandidate = #"{"vendor":"atlassian","client_id":"9f3a8d0e4b7c21","#
        + #""label":"Acme app","source":"stored","source_label":"Acme's saved company setup"}"#
    private static let googleCandidates = [
        #"{"vendor":"google","client_id":"1234-abcd.apps.googleusercontent.com","#
            + #""label":"acme-watchtower · 1234-abcd.apps.googleusercontent.com","source":"stored","#
            + #""source_label":"Acme's saved company setup"}"#,
        #"{"vendor":"google","client_id":"5678-efgh.apps.googleusercontent.com","#
            + #""label":"5678-efgh.apps.googleusercontent.com","source":"credentials_file","#
            + #""source_label":"the credentials file of alice@example.com"}"#
    ]
    private static let googleJSON = #"{"installed":{"client_id":"1234-abcd.apps.googleusercontent.com","#
        + #""client_secret":"sample-secret","project_id":"acme-watchtower"}}"#
    private static let confirmApp = #"{"result":"confirm_app","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
        + #""app_name":"Watchtower","client_id":"1111.2222","changes":{"add_scopes":["reactions:read","users:read.email"],"#
        + #""add_redirect_urls":["http://127.0.0.1:18551/slack/callback"],"enable_pkce":false}}"#
    private static let adoptOK = #"{"result":"ok","team_id":"T0ACME","team_name":"acme","app_id":"A0ACME","#
        + #""client_id":"1111.2222","link_written":false}"#
    private static let googleOK = #"{"result":"ok","slug":"acme","account_id":3,"email":"alice@example.com","#
        + #""domain":"example.com","checked":true}"#
    private static let atlassianOK = #"{"result":"ok","slug":"acme","account_id":7,"email":"alice@example.com","#
        + #""site":"https://acme.atlassian.net","checked":true,"confluence":true}"#
    private static let dryOK = #"{"result":"ok","checked":true}"#
    private static let consentURL = "https://login.microsoftonline.com/0000-acme/adminconsent?"
        + "client_id=4b1e0c9d-0000-4f00-a000-00000000077a"

    // MARK: Driving the model

    private static func make(_ cli: CompanyScriptedCLI) -> Model {
        let started = started
        return Model(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard)) { started }
    }

    /// A fresh setup (no draft on disk) opened with discovery's `candidates`.
    private static func fresh(candidates: [String] = [], setups: String = noSetups) -> (Model, CompanyScriptedCLI) {
        let cli = CompanyScriptedCLI()
        cli.setups = setups
        cli.on(["company", "discover"], [#"{"candidates":["# + candidates.joined(separator: ",") + "]}"])
        let model = make(cli)
        run { await model.open() }
        return (model, cli)
    }

    /// How a walk settles each step on the way to its target.
    private struct Walk {
        var skip: Set<CompanyVendor> = [.linear]
        /// Microsoft waits for admin consent (else its dry check passes).
        var microsoftWaits = true
        var googleCandidates: [String] = []
    }

    /// A fresh setup with every service ticked, walked to `target`: Slack
    /// reuses the found app (diff, then Update the app), Google and Atlassian
    /// pass their sign-in checks, Linear passes its dry check unless skipped,
    /// Microsoft waits for admin consent, the deny list gets two hosts.
    private static func walked(to target: Model.Step, _ walk: Walk = Walk()) -> (Model, CompanyScriptedCLI) {
        let (model, cli) = fresh(candidates: [slackCandidate] + walk.googleCandidates, setups: noSetups)
        for v in CompanyVendor.allCases where !model.ticked.contains(v) { model.toggle(v) }
        model.publishName = "Acme"
        var guardSteps = 0
        while model.current != target, guardSteps < 12 {
            guardSteps += 1
            settle(model, cli, walk)
        }
        return (model, cli)
    }

    private static func settle(_ model: Model, _ cli: CompanyScriptedCLI, _ walk: Walk) {
        switch model.current {
        case .services, .denyList:
            if model.current == .denyList { addHosts(model) }
            run { await model.next() }
        case let .vendor(v) where walk.skip.contains(v):
            run { await model.skip() }
        case .vendor(.slack):
            reuseSlack(model, cli)
        case .vendor(.google):
            model.createNew()
            model.dropGoogleClient(Data(googleJSON.utf8), fileName: "client_secret_1234-abcd.json")
            cli.on(["company", "check", "google"], [googleOK])
            run { await model.next() }
        case .vendor(.atlassian):
            fillAtlassian(model)
            cli.on(["company", "check", "atlassian"], [atlassianOK])
            run { await model.next() }
            model.atlassianConfirmed = [true, true, true]
            run { await model.next() }
        case .vendor(.linear):
            model.createNew()
            model.setField(.linear, .clientID, "lin-0000-acme")
            cli.on(["company", "check", "linear"], [dryOK])
            run { await model.next() }
        case .vendor(.microsoft):
            fillMicrosoft(model)
            cli.on(["company", "check", "microsoft"],
                   [walk.microsoftWaits ? #"{"result":"admin_consent","admin_consent_url":"\#(consentURL)"}"# : dryOK])
            run { await model.next() }
            if walk.microsoftWaits { run { await model.next() } }
        case .publish:
            break
        }
    }

    /// The found app: the token, the diff, **Update the app**; the step is Reused.
    private static func reuseSlack(_ model: Model, _ cli: CompanyScriptedCLI) {
        if let found = model.candidates(for: .slack).first { model.choose(found) }
        model.slackToken = token
        cli.on(["slack", "app", "adopt"], [confirmApp])
        start({ await model.next() }, until: { model.slackDiff != nil })
        cli.setups = acmeSetup
        cli.on(["slack", "app", "adopt"], [adoptOK])
        start({ await model.next() }, until: { model.current != .vendor(.slack) })
    }

    private static func fillAtlassian(_ model: Model) {
        model.createNew()
        model.setField(.atlassian, .clientID, "9f3a8d0e4b7c21")
        model.setField(.atlassian, .clientSecret, "sample-secret")
        model.setAtlassianSite("acme.atlassian.net")
    }

    private static func fillMicrosoft(_ model: Model) {
        model.createNew()
        model.setField(.microsoft, .clientID, "4b1e0c9d-0000-4f00-a000-00000000077a")
        model.setField(.microsoft, .tenantID, "0000-acme")
    }

    private static func addHosts(_ model: Model) {
        for host in Copy.denyHosts where !model.draft.denyHosts.contains(host) {
            model.hostField = host
            model.addHost()
        }
    }

    /// Runs `work` to its end on the main actor, turning the run loop meanwhile.
    private static func run(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        spin { done }
    }

    /// Starts `work` and turns the run loop until `condition` holds (a held run).
    private static func start(_ work: @escaping @MainActor () async -> Void, until condition: () -> Bool) {
        Task { @MainActor in await work() }
        spin(condition)
    }

    /// Turns the main run loop until `condition` holds (bounded; nothing waits on the clock once it holds).
    private static func spin(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    // MARK: Scenes

    private static func model(_ name: String) -> Model {
        if let model = pageScene(name) ?? servicesScene(name) { return model }
        if name.hasPrefix("slack-") { return slackScene(name) }
        if name.hasPrefix("google-") { return googleScene(name) }
        if name.hasPrefix("publish-") { return publishScene(name) }
        return laterScene(name)
    }

    private static func pageScene(_ name: String) -> Model? {
        let cli = CompanyScriptedCLI()
        let model = make(cli)
        switch name {
        case "loading":
            cli.hold(["company", "draft", "show"])
            start({ await model.open() }, until: { model.load == .loading })
        case "readFailed":
            // Every read fails: the page's own `.task` opens it again while it renders.
            for _ in 0..<8 { cli.on(["company", "draft", "show"], [], exit: 1) }
            run { await model.open() }
        case "looking":
            // Discovery runs as the page opens: a resumed draft at Slack sees it.
            let draft = #"{"company":"Acme","services":["slack","google","atlassian","linear","microsoft"],"#
                + #""step":"slack","started_at":"2026-11-17T09:00:00Z","slack":{}}"#
            cli.on(["company", "draft", "show"], [#"{"state":"ok","draft":\#(draft),"bad_file":"","checked_vendors":[]}"#])
            cli.hold(["company", "discover"])
            start({ await model.open() }, until: { model.discovering && !cli.calls(["company", "discover"]).isEmpty })
        default:
            return nil
        }
        return model
    }

    private static func servicesScene(_ name: String) -> Model? {
        switch name {
        case "services":
            return fresh().0
        case "services-found":
            return fresh(candidates: [slackCandidate, atlassianCandidate]).0
        case "draftUnreadable":
            let cli = CompanyScriptedCLI()
            cli.on(["company", "draft", "show"], [#"{"state":"unreadable","draft":null,"#
                + #""bad_file":"draft.json.bad-20261118-0412","checked_vendors":[]}"#])
            let model = make(cli)
            run { await model.open() }
            return model
        case "services-change":
            let (model, _) = walked(to: .vendor(.linear), Walk(skip: []))
            model.goTo(.services)
            model.toggle(.atlassian)
            return model
        default:
            return nil
        }
    }

    private static func slackScene(_ name: String) -> Model {
        let candidates = ["slack-found", "slack-progress", "slack-manifestDiff", "slack-notCollaborator"].contains(name)
        let (model, cli) = fresh(candidates: candidates ? [slackCandidate] : [])
        for v in CompanyVendor.allCases where !model.ticked.contains(v) { model.toggle(v) }
        run { await model.next() }
        switch name {
        case "slack-create", "slack-badToken":
            model.createNew()
            model.slackToken = token
            if name == "slack-badToken" {
                cli.on(["slack", "app", "create"], [#"{"result":"bad_token"}"#])
                start({ await model.next() }, until: { model.slackProblem != nil })
            }
        case "slack-existing":
            model.alreadyHaveOne()
            model.setField(.slack, .slackSettingsLink, "https://acme.slack.com/apps")
        case "slack-wrongWorkspace":
            model.alreadyHaveOne()
            model.setField(.slack, .slackSettingsLink, Copy.slackSettingsValue)
            run { await model.next() }
            model.slackToken = token
            cli.on(["slack", "app", "adopt"], [#"{"result":"wrong_workspace","team_id":"T0ACME","team_name":"acme","#
                + #""app_id":"A0ACME","app_team_id":"T0OTHER"}"#])
            start({ await model.next() }, until: { model.slackProblem != nil })
        case "slack-progress", "slack-manifestDiff", "slack-notCollaborator":
            if let found = model.candidates(for: .slack).first { model.choose(found) }
            model.slackToken = token
            switch name {
            case "slack-progress":
                let progress = [#"{"step":"check_token","state":"done"}"#, #"{"step":"read_app","state":"running"}"#]
                cli.hold(["slack", "app", "adopt"], first: progress)
                start({ await model.next() }, until: { model.slackProgress.contains { $0.mark == .running } })
            case "slack-manifestDiff":
                cli.on(["slack", "app", "adopt"], [confirmApp])
                start({ await model.next() }, until: { model.slackDiff != nil })
            default:
                cli.on(["slack", "app", "adopt"], [#"{"result":"not_collaborator","team_id":"T0ACME","team_name":"acme"}"#])
                start({ await model.next() }, until: { model.slackProblem != nil })
            }
        default:
            break // notFound, found: as the step opens
        }
        return model
    }

    private static func googleScene(_ name: String) -> Model {
        let found = name == "google-found" || name == "google-reuseSecret"
        let (model, cli) = walked(to: .vendor(.google), Walk(googleCandidates: found ? googleCandidates : []))
        switch name {
        case "google-reuseSecret":
            if let first = model.candidates(for: .google).first { model.choose(first) }
        case "google-create":
            model.createNew()
        case "google-noOrgAccess":
            model.createNew()
            model.showNoOrgAccess()
        case "google-checking", "google-checkFailed":
            model.createNew()
            model.dropGoogleClient(Data(googleJSON.utf8), fileName: "client_secret_1234-abcd.json")
            if name == "google-checking" {
                cli.hold(["company", "check", "google"])
                start({ await model.next() }, until: { model.isRunning(.google) })
            } else {
                cli.on(["company", "check", "google"], [#"{"result":"rejected","code":"invalid_client"}"#])
                run { await model.next() }
            }
        default:
            break // notFound, found: as the step opens
        }
        return model
    }

    private static func laterScene(_ name: String) -> Model {
        switch name {
        case "atlassian-create", "atlassian-signin", "atlassian-signinFailed", "atlassian-confirm":
            return atlassianScene(name)
        case "resume":
            return resumeScene()
        case "linear-create":
            let (model, _) = walked(to: .vendor(.linear), Walk(skip: []))
            model.createNew()
            return model
        case "microsoft-create", "microsoft-adminConsent", "microsoft-checkFailed":
            let (model, cli) = walked(to: .vendor(.microsoft))
            fillMicrosoft(model)
            if name == "microsoft-adminConsent" {
                cli.on(["company", "check", "microsoft"], [#"{"result":"admin_consent","admin_consent_url":"\#(consentURL)"}"#])
                run { await model.next() }
            } else if name == "microsoft-checkFailed" {
                cli.on(["company", "check", "microsoft"], [#"{"result":"rejected","code":"AADSTS700016"}"#])
                run { await model.next() }
            }
            return model
        default: // denyList, denyList-invalid
            let (model, _) = walked(to: .denyList, Walk(microsoftWaits: false))
            if name == "denyList" {
                addHosts(model)
            } else {
                model.hostField = "https://intranet.example.com/home"
                model.addHost()
            }
            return model
        }
    }

    private static func atlassianScene(_ name: String) -> Model {
        let (model, cli) = walked(to: .vendor(.atlassian))
        fillAtlassian(model)
        switch name {
        case "atlassian-signin":
            cli.hold(["company", "check", "atlassian"])
            start({ await model.next() }, until: { model.isRunning(.atlassian) })
        case "atlassian-signinFailed":
            cli.on(["company", "check", "atlassian"], [#"{"result":"rejected","code":"invalid_client"}"#])
            run { await model.next() }
        case "atlassian-confirm":
            cli.on(["company", "check", "atlassian"], [atlassianOK])
            run { await model.next() }
            model.atlassianConfirmed = [true, true, false]
        default:
            break
        }
        return model
    }

    /// A draft left at Atlassian (Google skipped), opened again later.
    private static func resumeScene() -> Model {
        let cli = CompanyScriptedCLI()
        cli.setups = acmeSetup
        let draft = #"{"company":"Acme","services":["slack","google","atlassian","linear","microsoft"],"#
            + #""step":"atlassian","started_at":"2026-11-17T09:00:00Z","slack":{"app_id":"A0ACME"},"skipped":["google"],"#
            + #""atlassian":{"client_id":"9f3a8d0e4b7c21","client_secret":"sample-secret","#
            + #""site":"https://acme.atlassian.net","confluence":true}}"#
        cli.on(["company", "draft", "show"], [#"{"state":"ok","draft":\#(draft),"bad_file":"","checked_vendors":[]}"#])
        let model = make(cli)
        run { await model.open() }
        return model
    }

    private static func publishScene(_ name: String) -> Model {
        let noSlack = name == "publish-done-noSlack"
        let (model, cli) = walked(to: .publish, Walk(skip: noSlack ? [.slack, .linear] : [.linear]))
        let result: String
        switch name {
        case "publish-busy":
            cli.hold(["company", "publish"], first: [#"{"step":"pack","state":"done"}"#,
                                                     #"{"step":"write_link","state":"running"}"#])
            start({ await model.next() }, until: { model.publishSteps.contains { $0.mark == .running } })
            return model
        case "publish-done", "publish-done-noSlack":
            result = #"{"result":"\#(noSlack ? "no_slack" : "ok")","slug":"acme","link":"\#(Copy.linkValue)","#
                + #""code":"\#(Copy.codeValue)"}"#
        case "publish-tokenExpired":
            result = #"{"result":"token_expired"}"#
        case "publish-failed":
            result = #"{"result":"network","message":"\#(Copy.publishFailed)"}"#
        default: // publish-ready
            return model
        }
        cli.on(["company", "publish"], [result])
        run { await model.next() }
        // The expired token is gone; a fresh one is pasted.
        if name == "publish-tokenExpired" { model.slackToken = "xoxe.xoxp-1-fresh-token" }
        return model
    }
}
