import Foundation

// Every string of the setup wizard (company screens spec §2), pinned by
// `CompanySetupWizardModelTests.testStringsEqualMockCopy` and held equal to
// the mockups' `CompanySetupMockCopy` by `CompanySetupMockCopyTests`.
extension CompanySetupWizardModel {
    // MARK: Frame (§2.2)

    package static let wizardTitle = "Set up Watchtower for your company"
    package static let wizardIntro = "One pass for every service your company uses. Each step can be skipped; Watchtower "
        + "keeps your progress, so you can leave this page and come back."
    package static let backToConnections = "Connections"
    package static let changeServices = "Change services"
    package static let skipStep = "Skip this step"
    package static let backTitle = "Back"
    package static let continueTitle = "Continue"
    package static let tryAgainTitle = "Try again"
    package static let doneTitle = "Done"
    package static let openTitle = "Open"
    package static let copyTitle = "Copy"

    package static func railName(_ step: Step) -> String {
        switch step {
        case .services: "Services"
        case let .vendor(v): CompanyVendorGuide.name(v)
        case .denyList: "Link deny list"
        case .publish: "Publish"
        }
    }

    /// The rail's word beside a mark (none for a step not started).
    package static func railWord(_ mark: StepMark) -> String? {
        switch mark {
        case .done: "Done"
        case .reused: "Reused"
        case .skipped: "Skipped"
        case .waiting: "Waiting"
        case .notStarted: nil
        }
    }

    /// "Step 3 of 8 · Google": the rail folded under 520 pt (A8).
    package var railNarrowLine: String {
        let index = steps.firstIndex(of: current) ?? 0
        return "Step \(index + 1) of \(steps.count) · \(Self.railName(current))"
    }

    // MARK: Resume, discard, unreadable draft

    package static func resumeLine(started: Date) -> String {
        // The Desktop is not localised: "Nov 17" whatever the Mac's region.
        let format = Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX"), timeZone: .current).month(.abbreviated).day()
        return "Continuing the setup you started on \(started.formatted(format))."
    }

    package static let discardSetup = "Discard setup"
    package static let discardConfirm = "Discard this setup? The draft and the secrets in it are deleted from this Mac. "
        + "Services you already signed in to stay connected and keep working. Apps you created stay in Slack, "
        + "Google, Atlassian, Linear and Microsoft."
    package static let discardButton = "Discard"
    package static let keepButton = "Keep"
    package static let draftUnreadableTitle = "Your unfinished setup could not be read — start again"
    package static func draftUnreadableBody(file: String) -> String {
        "Watchtower kept the file as \(file) next to your company setups, so nothing you typed is lost; Discard or Publish "
            + "deletes it."
    }

    package static let showInFinder = "Show file in Finder"
    /// The page while the draft is read.
    package static let loadingLine = "Reading the setup's progress on this Mac…"
    package static let draftReadFailed = "Watchtower could not read the setup's progress on this Mac. Try opening this page again."
    static let draftSaveFailed = "Watchtower could not save the setup's progress on this Mac, so nothing was checked. "
        + "Try again."
    static let discardFailed = "Watchtower could not delete the setup's draft on this Mac. Try again."
    static let noAnswer = "the watchtower command gave no result"

    // MARK: Services (§2.3)

    /// One row per supported service, ticked or not, with "Found on this Mac".
    package var servicesRows: [(vendor: CompanyVendor, title: String, detail: String, ticked: Bool)] {
        CompanyVendor.allCases.map { v in
            let row = CompanyVendorGuide.servicesRow(v)
            let detail = foundVendors.contains(v) ? "\(row.detail) · \(CompanyVendorGuide.foundOnMac)" : row.detail
            return (v, row.title, detail, ticked.contains(v))
        }
    }

    package static func dropWarningFor(_ v: CompanyVendor) -> DropWarning {
        let name = CompanyVendorGuide.name(v)
        let entries = switch v {
        case .slack: "the app you chose"
        case .google, .atlassian: "client id and secret"
        case .linear: "client id"
        case .microsoft: "client and tenant ids"
        }
        let home = v == .microsoft ? "Microsoft" : name
        return DropWarning(vendor: v, title: "Stop setting up \(name)?",
                           body: "What you entered for it (\(entries)) is dropped from the draft. An app you created stays in \(home).",
                           drop: "Drop \(name)", keep: keepButton)
    }

    // MARK: Existing apps first (§2.4)

    package static let foundTitle = "Found on this Mac"
    package static let createNew = "Create new"
    package static let createNewDetail = "Watchtower walks you through creating it."
    package static let alreadyHaveOne = "We already have one"
    package static let alreadyHaveDetail = "Paste what identifies it; Watchtower checks it before going on."
    package static let useSelected = "Use the selected client"
    package static let useThisClient = "Use this client"
    package static let reuseSecretBody = "This Mac knows the client id but not its secret. Open the client in Cloud Console, "
        + "copy its secret and paste it here."
    package static let openClient = "Open the client"
    /// The Google client's page in Cloud Console.
    package static func clientURL(_ clientID: String) -> URL? {
        URL(string: "https://console.cloud.google.com/apis/credentials/oauthclient/\(clientID)")
    }

    static func savedSetupSource(_ company: String) -> String {
        company.isEmpty ? "your saved company setup" : "\(company)'s saved company setup"
    }

    // MARK: Slack (§2.5; the token form is Slack spec §3.2's)

    package static let slackTokenStep1 = "1. Generate a configuration token"
    package static let slackTokenHelp = "On Slack's app page, under Your App Configuration Tokens, press Generate Token "
        + "for your workspace and copy the access token."
    package static let openTokenPage = "Open Slack's token page"
    package static let slackTokenStep2 = "2. Paste it here"
    package static let tokenPlaceholder = "Configuration token"
    package static let tokenNote = "Used once for this setup and never stored."
    package static let createApp = "Create the app"
    package static let updateApp = "Update the app"
    package static let slackProgressCaption = "You can leave this page: the setup resumes at this step, and the app is "
        + "never created twice."
    static let updatingApp = "Updating the app"
    package static let comparingApp = "Comparing them with Watchtower's"
    package static func readingApp(_ appID: String) -> String { "Reading app \(appID)'s settings" }
    package static func manifestDiffTitle(_ appID: String) -> String { "App \(appID)'s settings differ from Watchtower's" }
    /// The diff found nothing to change.
    package static func manifestSameTitle(_ appID: String) -> String { "App \(appID) already has Watchtower's settings" }
    package static let manifestSameBody = "Using it changes nothing in it."
    /// **Use <app>**: the found app's name (its label up to " · ").
    package static func useApp(_ label: String) -> String {
        "Use \(label.components(separatedBy: " · ").first ?? label)"
    }

    static func slackAppLabel(_ appID: String) -> String { "Watchtower · \(appID)" }
    package static let discoveryFailed = "Watchtower could not look for the apps this Mac already knows. You can still "
        + "create one or paste what identifies yours."
    package static let manifestDiffBody = "Watchtower will make these changes to the app. Nothing else in it changes."
    package static func diffLines(_ changes: SlackAppChanges?) -> [String] {
        guard let changes else { return [] }
        var lines: [String] = []
        if !changes.addScopes.isEmpty { lines.append("Add scopes: \(changes.addScopes.joined(separator: ", "))") }
        for url in changes.addRedirectURLs { lines.append("Add redirect URL: \(url)") }
        if changes.enablePKCE { lines.append("Turn on PKCE sign-in") }
        return lines
    }

    package static func notCollaborator(appID: String) -> String {
        "You are not a collaborator on app \(appID), so Slack does not let you change it. Ask the app's owner to add you "
            + "as a collaborator, then try again."
    }

    package static let slackSettingsInvalid = "That is not a Slack app settings link. It looks like "
        + "https://api.slack.com/apps/A0123ABCD."

    // MARK: Google (§2.6)

    package static let dropJSON = "Drop the client JSON here, or paste it"
    /// The drop zone's file line for JSON pasted rather than dropped.
    package static let pastedJSON = "Pasted client JSON"
    package static let googleFileInvalid = "That is not a Google OAuth client JSON. Download it again from Credentials → "
        + "OAuth 2.0 Client IDs."
    /// "client_secret_1234-abcd.json · project acme-watchtower"
    package var droppedGoogleLine: String? {
        googleFile.map { $0.project.isEmpty ? $0.name : "\($0.name) · project \($0.project)" }
    }

    package static let checkingGoogle = "Finish in your browser: sign in to Google with this client. Your sign-in checks "
        + "the client and connects your own Google account."
    package static let noOrgLink = "Can't create a project in your organization?"
    package static let noOrgTitle = "An Internal app needs your company's Google Cloud organization"
    package static func noOrgBody(domain: String) -> String {
        let org = domain.isEmpty ? "your company's" : "\(domain)'s"
        return "The project must sit inside \(org) Google Cloud organization. If you cannot create one there, or Internal is "
            + "not offered, ask your Google Workspace admin to create the project or to give you the Project Creator role. "
            + "Then drop the client JSON they send you here."
    }

    package static let copyStepsForAdmin = "Copy the steps for your admin"

    /// **Copy the steps for your admin**: the vendor's guide as text, links included.
    package static func adminSteps(_ v: CompanyVendor) -> String {
        let lines = CompanyVendorGuide.guideLines(v).enumerated().map { index, line in
            "\(index + 1). \(line.text)" + (line.link.map { " — \($0.absoluteString)" } ?? "")
        }
        return lines.joined(separator: "\n")
    }

    package static func connectedLine(_ email: String) -> String { "Connected as \(email)" }

    // MARK: Atlassian (§2.7)

    package static let checkBySignin = "Check by signing in"
    package static let replaceAndCheck = "Replace and sign in"
    package static let siteLabel = "Site"
    package static let sitePlaceholder = "acme.atlassian.net"
    package static let atlassianSigninWait = "Finish in your browser: sign in to Atlassian with this app. Your sign-in "
        + "checks the client id, the secret and the callback URLs, and connects your own Atlassian account."
    package static let confirmTitle = "Confirm the app's settings"
    package static let confirmBody = "Atlassian gives Watchtower no way to read these. Check each one in the developer "
        + "console, then tick it."
    package static let confirmChecks = [
        "Sharing is on (Distribution)",
        "“Does your app store personal data?” is Yes",
        "report:personal-data is among the permissions"
    ]
    /// Each confirm line's **Open**: the developer console's app list.
    package static let confirmLink = URL(string: "https://developer.atlassian.com/console/myapps/")
    package static let publishWaitsAtlassianConfirm = "Publish waits for the Atlassian settings: tick the three items "
        + "on the Atlassian step."
    /// Go `company.AdminConsentURL`.
    static func adminConsentURL(tenant: String, clientID: String) -> String {
        "https://login.microsoftonline.com/\(tenant)/adminconsent?client_id=\(clientID)"
    }

    static func publishDraftLeft(_ detail: String) -> String {
        "Published. The setup's draft could not be deleted from this Mac (\(detail)); Discard setup removes it."
    }

    package static let publishWaitsAtlassian = "Publish waits for the Atlassian check: sign in on the Atlassian step, or "
        + "skip Atlassian."

    // MARK: Linear and Microsoft (§2.8)

    package static let consentTitle = "Your IT admin must approve Watchtower in Microsoft 365"
    package static let consentBody = "Grant admin consent needs a tenant admin. Send your IT admin this link; you can go on "
        + "with the setup meanwhile. Microsoft 365 shows as waiting until they approve."
    package static let consentLinkLabel = "Admin consent link"
    package static let checkAgain = "Check again"

    // MARK: Check lines

    /// The busy line while a check runs.
    package static func checkingLine(_ v: CompanyVendor) -> String {
        switch v {
        case .google: checkingGoogle
        case .atlassian: atlassianSigninWait
        case .linear: "Checking the client with Linear…"
        case .microsoft: "Checking the client with Microsoft…"
        case .slack: ""
        }
    }

    package static func rejectedLine(_ v: CompanyVendor, code: String, tenant: String) -> String {
        switch v {
        case .google:
            "Google does not accept this client: \(code). Download the JSON again from Credentials."
        case .atlassian:
            "Atlassian refused the sign-in: \(code). Check the client id and secret, and that Watchtower's callback URLs "
                + "are in the app's Authorization settings."
        case .linear:
            "Linear does not accept this client: \(code). Copy the client id again from the app's page in Linear."
        case .microsoft:
            "Microsoft does not accept this client in tenant \(tenant): \(code). Check both ids on the app's Overview page."
        case .slack:
            code
        }
    }

    package static func networkLine(_ v: CompanyVendor, _ error: String) -> String {
        "Could not reach \(v == .microsoft ? "Microsoft" : CompanyVendorGuide.name(v)): \(error). Nothing was saved."
    }

    static func cancelledLine(_ detail: String) -> String {
        let why = detail.isEmpty ? "" : ": \(detail)"
        return "The sign-in did not finish\(why). Nothing was saved."
    }

    static func notRecorded(_ detail: String) -> String {
        let why = detail.isEmpty ? "" : ": \(detail)"
        return "The sign-in worked, but Watchtower could not record the check in this setup\(why). Your account stays "
            + "connected; check again."
    }

    static func appIDProblemLine(_ problem: SlackAppSetupModel.AppIDProblem, appID: String) -> String {
        switch problem {
        case .format: "That is not a Slack app settings link. It looks like https://api.slack.com/apps/A0123ABCD."
        case .mismatch: "This workspace's Watchtower app is another one than \(appID). Check the link and paste it again."
        case .notFound: "Slack has no app \(appID) this token can see. Check the link and paste it again."
        }
    }

    static let checkStopped = "The check stopped before it answered. Nothing was saved; try again."
    static let nameNeeded = "Watchtower needs your company's name before this check: colleagues see “Connect <name>?”. "
        + "Enter it under Company name."

    /// The step's line under its fields: the check's state in words.
    package func checkLine(_ v: CompanyVendor) -> String? {
        switch checks[v] {
        case .running?: return Self.checkingLine(v)
        case let .failed(line)?: return line
        case .replaceNeeded?: return Self.replaceWarning(company: draft.company, vendor: v)
        case .adminConsent?: return nil
        case .passed?, .idle?, nil:
            if forcedVendors.contains(v) { return Self.forcedLine(draft.company) }
            if isChecked(v), let email = connectedAs[v] { return Self.connectedLine(email) }
            return nil
        }
    }

    static func replaceWarning(company: String, vendor: CompanyVendor) -> String {
        let name = CompanyVendorGuide.name(vendor)
        return "\(company)'s stored \(name) app will be replaced; your other \(company) \(name) accounts will need to log in again."
    }

    static func forcedLine(_ company: String) -> String {
        "Your organization sets \(company)'s apps on this Mac; what you set up here is used once the profile is removed."
    }

    // MARK: Deny list (§2.9)

    package static let denyBody = "Watchtower never opens links to these hosts — your intranet and internal tools. "
        + "Colleagues cannot remove them; their own settings can only add more."
    package static let addHostLabel = "Add a host"
    package static let addTitle = "Add"
    package static let removeTitle = "Remove"
    package static let denyInvalid = "That is not a host name. Enter it like intranet.example.com, without https:// or a path."

    // MARK: Publish (§2.10)

    package static let companyNameLabel = "Company name"
    package static let publishTitle = "Publish"
    package static let connectThisMacTitle = "Connect this Mac"
    package static let publishCaption = "Writes the connect link and code to the About page of Watchtower's app in Slack."
    package static let publishCaptionNoSlack = "Slack is not part of this setup, so no About page gets the link: Publish "
        + "gives you the link, the code and the profile."
    package static let publishNeedsTokenLine = "Paste a configuration token to write the link to the Slack page. "
        + "It is used once and never stored."
    package static let publishTokenExpiredLine = "The configuration token has expired, so the link is not on the Slack page "
        + "yet. Your setup is kept. Generate a fresh token and paste it."
    static let publishNetworkFallback = "Could not reach Slack. Your setup is kept."
    static let publishWrongWorkspace = "That configuration token is for another Slack workspace than the company's app. "
        + "Generate one in the app's workspace and paste it."
    static func publishWaits(_ v: CompanyVendor) -> String {
        let name = CompanyVendorGuide.name(v)
        return switch v {
        case .google: "Publish waits for the Google check: sign in on the Google step, or skip Google."
        default: "Publish waits for the \(name) step: finish it, or skip it."
        }
    }

    static func publishStopped(_ detail: String) -> String {
        "Publish stopped before it finished: \(detail). Your setup is kept; try again."
    }

    static func publishRefused(_ detail: String) -> String {
        "Publish did not go through: \(detail). Your setup is kept."
    }

    /// `name_taken`: another company on this Mac (or the person's own Google
    /// project) already has the typed name. A rename itself just publishes
    /// (ask #1613: only the display name changes).
    static func publishNameTaken(_ typed: String) -> String {
        "“\(typed)” is already the name of another company on this Mac, or of your own Google project. "
            + "Choose another name."
    }

    /// `company_forced`: the organization's managed preferences set the name.
    static func publishNameForced(_ stored: String) -> String {
        "Your organization sets this company's name, so it is published as “\(stored)”."
    }

    package static func publishStepLines(slack: Bool) -> [SlackAppSetupModel.StepLine] {
        var lines = [SlackAppSetupModel.StepLine(id: "pack", label: "Packing the company setup", mark: .waiting)]
        if slack {
            lines.append(.init(id: "write_link", label: "Writing the link to the Slack app's About page", mark: .waiting))
        }
        return lines
    }

    /// Under the name field: where the name came from (A2).
    package var companyNameHelp: String {
        let name = publishName.isEmpty ? "<name>" : publishName
        let source = switch derivedName().source {
        case .slack?: " Taken from your Slack workspace; change it if people know the company by another name."
        case .google?: " Taken from your Google Workspace domain; change it if people know the company by another name."
        case .atlassian?: " Taken from your Atlassian site; change it if people know the company by another name."
        default: ""
        }
        return "Colleagues see “Connect \(name)?”." + source
    }

    /// One line per supported service, then the deny list (§2.10).
    package var publishSummary: [String] {
        var lines = CompanyVendor.allCases.map { v in
            isActive(v) ? summaryLine(v) : CompanyVendorGuide.notUsedLine(v, skipped: ticked.contains(v))
        }
        let hosts = draft.denyHosts.count
        lines.append("Link deny list · " + (hosts == 0 ? "none" : hosts == 1 ? "1 host" : "\(hosts) hosts"))
        return lines
    }

    private func summaryLine(_ v: CompanyVendor) -> String {
        switch v {
        case .slack:
            let record = slack.record(appID: draft.slack.appID)
            let team = record.map { $0.teamName.isEmpty ? $0.teamID : $0.teamName } ?? ""
            return "Slack · Watchtower (\(draft.slack.appID))" + (team.isEmpty ? "" : " in \(team)")
        case .google:
            let google = draft.google ?? .init()
            let what = googleFile.map { $0.project }.flatMap { $0.isEmpty ? nil : $0 } ?? "client \(Self.short(google.clientID))"
            return "Google · \(what)" + (google.domain.isEmpty ? "" : " · \(google.domain)")
        case .atlassian:
            let a = draft.atlassian ?? .init()
            let host = URL(string: a.site)?.host ?? a.site
            let confluence = a.confluence && !confluenceRefused ? "Confluence on" : "Confluence off"
            return "Atlassian · client \(Self.short(a.clientID)) · \(host) · \(confluence) · checked and connected by your sign-in"
        case .linear:
            return "Linear · client \(Self.short(draft.linear?.clientID ?? ""))"
        case .microsoft:
            let m = draft.microsoft ?? .init()
            let waiting = draft.microsoftWaiting && !isChecked(.microsoft) ? " · waiting for admin consent" : ""
            return "Microsoft 365 · client \(Self.short(m.clientID)) · tenant \(m.tenantID)\(waiting)"
        }
    }

    /// An id shortened to its first 4 and last 3 characters (A21).
    static func short(_ id: String) -> String {
        id.count > 8 ? "\(id.prefix(4))…\(id.suffix(3))" : id
    }

    // MARK: Publish done

    package static func publishedTitle(_ company: String) -> String { "\(company) is set up" }
    package static let publishedBody = "Colleagues open Watchtower's app in Slack, go to About and click the link. Without "
        + "Slack, send them the code, or give IT the profile. Your checked services are already connected; "
        + "Connect this Mac adds the rest."
    package static let publishedNoSlack = "Slack was skipped, so no page carries the link. Send colleagues the code, "
        + "or give IT the profile. Your checked services are already connected; Connect this Mac adds the rest."
    package static let linkLabel = "Connect link"
    package static let codeLabel = "Connect code"
    package static let profileLabel = "Configuration profile for IT"
    package static let saveProfile = "Save…"
    package static func profileFileName(_ company: String) -> String { "\(company)-Watchtower.mobileconfig" }
    package static let profileFailed = "Watchtower could not make the configuration profile. Try again."
    package static func profileSaveFailed(_ detail: String) -> String {
        "The configuration profile could not be saved: \(detail)."
    }
}
