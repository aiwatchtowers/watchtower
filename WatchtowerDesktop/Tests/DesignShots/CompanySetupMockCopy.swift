import Foundation

/// Design-only string table of the company setup screens spec
/// (`docs/superpowers/specs/2026-11-18-company-setup-screens-design.md`).
/// The implementation moves each group into the model the spec names
/// (`CompanySetupWizardModel`, `CompanyVendorGuide`, `CompanyConnectFlowModel`,
/// `CompanyConnectionsPresentation`, `OwnGoogleProjectModel`,
/// `AtlassianTokenFormModel`, `ManagedPolicyHelp`, Go `internal/oauthpage`)
/// and pins it there; `CompanySetupMockCopyTests` pins this table so the
/// mockups and the spec cannot drift. Sample data only: `Acme`, `acme`,
/// `example.com`, made-up ids.
enum CompanySetupMockCopy {
    // MARK: Shared buttons

    static let cancel = "Cancel"
    static let done = "Done"
    static let back = "Back"
    static let continueStep = "Continue"
    static let tryAgain = "Try again"
    static let connect = "Connect"
    static let open = "Open"
    static let copy = "Copy"
    static let skipStep = "Skip this step"
    static let backToConnections = "Connections"
    static let backToGoogle = "Google"
    static let notConnected = "Not connected"

    // MARK: Wizard frame (§2)

    static let wizardTitle = "Set up Watchtower for your company"
    static let wizardIntro = "One pass for every service your company uses. Each step can be skipped; Watchtower keeps "
        + "your progress, so you can leave this page and come back."
    /// The rail of a wizard where every service is ticked: Services first, then one step
    /// per ticked service, then the deny list and Publish.
    static let railSteps = ["Services", "Slack", "Google", "Atlassian", "Linear", "Microsoft 365", "Link deny list", "Publish"]
    static let railDone = "Done"
    static let railReused = "Reused"
    static let railSkipped = "Skipped"
    static let railWaiting = "Waiting"
    static let narrowStepLine = "Step 3 of 8 · Google"
    /// "Step <n> of <count> · <step>", the wizard's one-line rail at narrow width.
    static func stepLine(_ index: Int, of rail: [String] = railSteps) -> String {
        "Step \(index + 1) of \(rail.count) · \(rail[index])"
    }
    static let changeServices = "Change services"

    // MARK: Services step (first)

    static let servicesTitle = "What does your company use?"
    static let servicesBody = "Tick what your company has. Each ticked service gets its own step; the link deny list "
        + "and Publish always follow."
    /// One row per supported service: the name and a one-line description.
    static let services = [
        ("Slack", "Messages, digests and the Inbox"),
        ("Google Workspace — Gmail and Calendar", "Mail and calendar through your company's Google project"),
        ("Atlassian — Jira and Confluence", "Issues and pages through your company's Atlassian app"),
        ("Linear", "Issues through your company's Linear app"),
        ("Microsoft 365 — Outlook", "Mail through your company's Entra app")
    ]
    static let foundOnMac = "Found on this Mac"
    static let mcpNote = "Use something else (Notion, GitHub, a CRM…)? Connect it yourself in Connections → "
        + "Quick Connections (MCP connectors)."
    static let openQuickConnections = "Open Quick Connections"
    static let dropServiceTitle = "Stop setting up Atlassian?"
    static let dropServiceBody = "What you entered for it (client id and secret) is dropped from the draft. "
        + "An app you created stays in Atlassian."
    static let dropService = "Drop Atlassian"
    static let keepService = "Keep"
    static let draftUnreadableTitle = "Your unfinished setup could not be read — start again"
    static let draftUnreadableBody = "Watchtower kept the file as draft.json.bad-20261118-0412 next to your company "
        + "setups, so nothing you typed is lost; Discard or Publish deletes it."
    static let showInFinder = "Show file in Finder"
    static let resumeLine = "Continuing the setup you started on Nov 17."
    static let discardSetup = "Discard setup"
    static let discardConfirm = "Discard this setup? The draft and the secrets in it are deleted from this Mac. "
        + "Services you already signed in to stay connected and keep working. Apps you created stay in Slack, "
        + "Google, Atlassian, Linear and Microsoft."

    // MARK: Existing apps first (D19)

    static let lookingSlack = "Looking for Slack apps this Mac already knows…"
    static let foundTitle = "Found on this Mac"
    static let foundSlackApp = "Watchtower · A0ACME"
    static let foundSlackSource = "Slack app — your connected account acme"
    static let useSlackApp = "Use Watchtower"
    static let createNew = "Create new"
    static let reuseCaption = "Reusing keeps the app and its ids; nothing new is created. A configuration token "
        + "is still needed to check and update its settings."
    static let foundGoogleA = "acme-watchtower · 1234-abcd.apps.googleusercontent.com"
    static let foundGoogleASource = "Acme's saved company setup"
    static let foundGoogleB = "5678-efgh.apps.googleusercontent.com"
    static let foundGoogleBSource = "the credentials file of alice@example.com"
    static let useSelected = "Use the selected client"
    static let notFoundGoogle = "No Google client found on this Mac."
    static let alreadyHaveOne = "We already have one"
    static let createNewDetail = "Watchtower walks you through creating it."
    static let alreadyHaveDetail = "Paste what identifies it; Watchtower checks it before going on."
    static let notSureSlack = "Not sure? In Slack, open Apps and search for Watchtower. If it is there, someone already created it."
    static let notSureGoogle = "Not sure? Look in Google Cloud Console → APIs & Services → Credentials, under OAuth 2.0 Client IDs."
    static let notSureAtlassian = "Not sure? Look in the Atlassian developer console → My apps."
    static let notSureLinear = "Not sure? Look in Linear → Settings → API → OAuth applications."
    static let notSureMicrosoft = "Not sure? Look in the Microsoft Entra admin center → App registrations → All applications."
    static let reuseSecretBody = "This Mac knows the client id but not its secret. Open the client in Cloud Console, "
        + "copy its secret and paste it here."
    static let openClient = "Open the client"
    static let clientSecret = "Client secret"

    // MARK: Slack step

    static let slackTokenStep1 = "1. Generate a configuration token"
    static let slackTokenHelp = "On Slack's app page, under Your App Configuration Tokens, press Generate Token "
        + "for your workspace and copy the access token."
    static let openTokenPage = "Open Slack's token page"
    static let slackTokenStep2 = "2. Paste it here"
    static let tokenPlaceholder = "Configuration token"
    static let tokenNote = "Used once for this setup and never stored."
    static let createApp = "Create the app"
    static let slackReuseSteps = ["Checking the token", "Reading app A0ACME's settings", "Comparing them with Watchtower's"]
    static let slackProgressCaption = "You can leave this page: the setup resumes at this step, "
        + "and the app is never created twice."
    static let manifestDiffTitle = "App A0ACME's settings differ from Watchtower's"
    static let manifestDiffBody = "Watchtower will make these changes to the app. Nothing else in it changes."
    static let manifestDiffLines = [
        "Add scopes: reactions:read, users:read.email",
        "Add redirect URL: http://127.0.0.1:18551/slack/callback"
    ]
    static let updateApp = "Update the app"
    static let notCollaborator = "Slack would not let this token change app A0ACME (no_permission). The token has to "
        + "come from the workspace the app was made in, from one of its collaborators: make a new token there and try "
        + "again."
    static let wrongWorkspace = "App A0ACME belongs to another workspace (T0OTHER), not acme. "
        + "Check the link and paste it again."
    static let slackSettingsLink = "App settings link"
    static let slackSettingsValue = "https://api.slack.com/apps/A0ACME"
    static let slackSettingsHelp = "Open the app on api.slack.com and copy the address of its settings page."
    static let slackSettingsInvalid = "That is not a Slack app settings link. It looks like https://api.slack.com/apps/A0123ABCD."
    static let badToken = "That token did not work: it has expired or is not a configuration token. "
        + "Generate a new one and paste it."

    // MARK: Google step

    static let googleGuide = [
        "Create a project",
        "Turn on the Gmail API and the Google Calendar API",
        "OAuth consent screen: user type Internal",
        "Credentials → Create OAuth client → Desktop app, then download its JSON"
    ]
    static let dropJSON = "Drop the client JSON here, or paste it"
    static let droppedJSON = "client_secret_1234-abcd.json · project acme-watchtower"
    static let checkingGoogle = "Finish in your browser: sign in to Google with this client. Your sign-in checks the "
        + "client and connects your own Google account."
    static let googleRejected = "Google does not accept this client: invalid_client. Download the JSON again from Credentials."
    static let noOrgLink = "Can't create a project in your organization?"
    static let noOrgTitle = "An Internal app needs your company's Google Cloud organization"
    static let noOrgBody = "The project must sit inside example.com's Google Cloud organization. If you cannot create "
        + "one there, or Internal is not offered, ask your Google Workspace admin to create the project or to give you "
        + "the Project Creator role. Then drop the client JSON they send you here."
    static let copyStepsForAdmin = "Copy the steps for your admin"
    static let googleNetwork = "Could not reach Google: the request timed out. Nothing was saved."

    // MARK: Atlassian step

    static let atlassianGuide = [
        "Create an OAuth 2.0 integration",
        "Permissions: add the Jira API and the Confluence API with Watchtower's scopes, and report:personal-data",
        "Authorization: add Watchtower's callback URLs",
        "Distribution: turn Sharing on and answer Yes to “Does your app store personal data?”",
        "Add a second admin as an owner, so the app outlives one person"
    ]
    static let copyScopes = "Copy scopes"
    static let atlassianSigninWait = "Finish in your browser: sign in to Atlassian with this app. Your sign-in checks "
        + "the client id, the secret and the callback URLs, and connects your own Atlassian account."
    static let atlassianSigninFailed = "Atlassian refused the sign-in: invalid_client. Check the client id and secret, "
        + "and that Watchtower's callback URLs are in the app's Authorization settings."
    static let checkBySignin = "Check by signing in"
    static let publishWaitsAtlassian = "Publish waits for the Atlassian check: sign in on the Atlassian step, or skip "
        + "Atlassian."
    static let copyCallbacks = "Copy callback URLs"
    static let clientID = "Client ID"
    static let confirmTitle = "Confirm the app's settings"
    static let confirmBody = "Atlassian gives Watchtower no way to read these. Check each one in the developer console, "
        + "then tick it."
    static let confirmChecks = [
        "Sharing is on (Distribution)",
        "“Does your app store personal data?” is Yes",
        "report:personal-data is among the permissions"
    ]

    // MARK: Linear and Microsoft steps

    static let linearGuide = [
        "Settings → API → OAuth applications → New application",
        "Callback URL: paste Watchtower's"
    ]
    static let copyCallback = "Copy callback URL"
    static let linearNote = "No secret: Watchtower signs in with PKCE."
    static let microsoftGuide = [
        "App registrations → New registration: Accounts in this organizational directory only",
        "Platform: Mobile and desktop applications, redirect URI http://localhost",
        "API permissions: add the Outlook permissions, then Grant admin consent"
    ]
    static let copyPermissions = "Copy permissions"
    static let consentTitle = "Your IT admin must approve Watchtower in Microsoft 365"
    static let consentBody = "Grant admin consent needs a tenant admin. Send your IT admin this link; you can go on "
        + "with the setup meanwhile. Microsoft 365 shows as waiting until they approve."
    static let consentLinkLabel = "Admin consent link"
    static let consentLinkValue = "https://login.microsoftonline.com/0000-acme/adminconsent?client_id=4b1e…77a"
    static let checkAgain = "Check again"
    static let microsoftClientID = "Application (client) ID"
    static let microsoftTenantID = "Directory (tenant) ID"
    static let microsoftNote = "No secret: Watchtower signs in with PKCE against your tenant."
    static let microsoftRejected = "Microsoft does not accept this client in tenant 0000-acme: AADSTS700016. "
        + "Check both ids on the app's Overview page."

    // MARK: Link deny list step

    static let denyTitle = "Link deny list"
    static let denyBody = "Watchtower never opens links to these hosts — your intranet and internal tools. "
        + "Colleagues cannot remove them; their own settings can only add more."
    static let addHost = "Add a host"
    static let add = "Add"
    static let denyHosts = ["intranet.example.com", "wiki.corp.example.com"]
    static let denyInvalid = "That is not a host name. Enter it like intranet.example.com, without https:// or a path."

    // MARK: Publish step

    static let companyName = "Company name"
    static let companyNameHelp = "Colleagues see “Connect Acme?”. Taken from your Slack workspace; change it if people "
        + "know the company by another name."
    static let publishSummary = [
        "Slack · Watchtower (A0ACME) in acme",
        "Google · acme-watchtower · example.com",
        "Atlassian · client 9f3a…c21 · acme.atlassian.net · Confluence on · checked and connected by your sign-in",
        "Linear · skipped: colleagues use Watchtower's shared Linear app",
        "Microsoft 365 · client 4b1e…77a · tenant 0000-acme · waiting for admin consent",
        "Link deny list · 2 hosts"
    ]
    static let publishCaption = "Writes the connect link and code to the About page of Watchtower's app in Slack."
    static let publish = "Publish"
    static let publishSteps = ["Packing the company setup", "Writing the link to the Slack app's About page"]
    static let publishedTitle = "Acme is set up"
    static let publishedBody = "Colleagues open Watchtower's app in Slack, go to About and click the link. Without "
        + "Slack, send them the code, or give IT the profile. Your checked services are already connected; "
        + "Connect this Mac adds the rest."
    static let publishedNoSlack = "Slack was skipped, so no page carries the link. Send colleagues the code, "
        + "or give IT the profile. Your checked services are already connected; Connect this Mac adds the rest."
    static let linkLabel = "Connect link"
    static let linkValue = "http://127.0.0.1:18551/company/connect?b=eyJ2IjoxLCJjb21wYW55IjoiQWNtZSIs…"
    static let codeLabel = "Connect code"
    static let codeValue = "eyJ2IjoxLCJjb21wYW55IjoiQWNtZSIs…"
    static let profileLabel = "Configuration profile for IT"
    static let profileValue = "Acme-Watchtower.mobileconfig"
    static let saveProfile = "Save…"
    static let connectThisMac = "Connect this Mac"
    static let publishTokenExpired = "The configuration token has expired, so the link is not on the Slack page yet. "
        + "Your setup is kept. Generate a fresh token and paste it."
    static let publishNeedsToken = "Paste a configuration token to write the link to the Slack page. "
        + "It is used once and never stored."
    static let publishFailed = "Could not reach Slack: the request timed out. Your setup is kept."

    // MARK: MDM help link (D21)

    static let itGuideLink = "What IT can set"
    static let itGuideRow = "IT guide"
    static let itGuideCaption = "Every setting a configuration profile can force, with a sample profile."

    // MARK: The employee: confirm, chain, replace (§3)

    static let confirmConnectTitle = "Connect Acme?"
    static let confirmLinkBody = "A link asks Watchtower to connect your accounts through Acme's apps. "
        + "Connect only if you opened this link yourself."
    static let confirmCodeBody = "This code connects your accounts through Acme's apps."
    static let mdmTitle = "Acme — Connect all"
    static let mdmBody = "Your organization set up Acme's apps on this Mac."
    static let vendorRows = [
        ("Slack", "workspace acme"),
        ("Gmail and Calendar", "example.com"),
        ("Jira and Confluence", "acme.atlassian.net"),
        ("Outlook", "Microsoft 365"),
        ("Linear", "Acme's Linear app")
    ]
    static let confirmCaption = "Each service opens its own sign-in page in your browser, one after another."
    static let alreadyConnected = "Connected"
    static let chainTitle = "Connecting Acme"
    static let chainSlackDone = "Connected as alice"
    static let chainBrowserGoogle = "Finish in your browser: Google asks you to allow Watchtower."
    static let chainBrowserAtlassian = "Finish in your browser: Atlassian asks you to allow Watchtower."
    static let chainNext = "Next"
    static let chainDenied = "You did not allow Watchtower. Connect it later from Connections."
    static let chainFailed = "Could not connect: the request timed out. Connect it later from Connections."
    static let chainCaption = "You can close this window: the chain goes on and Connections shows where it is."
    static let skipService = "Skip this service"
    static let stop = "Stop"
    static let chainDoneAll = "Acme is connected"
    static let chainDonePartial = "Acme is partly connected"
    static let chainDoneBody = "The first sync starts now. What is not connected waits in Connections with a Connect button."
    static let chainSkipped = "Skipped"
    static let replaceTitle = "Acme's link changes its apps"
    static let replaceBody = "Keep your current setup unless your admin told you the apps changed. Replacing asks "
        + "you to log in again to what changed."
    static let replaceLines = [
        "Atlassian app: 9f3a…c21 → 7b20…e04",
        "Google client: 1234-abcd… → 5678-efgh…"
    ]
    static let replaceCaption = "Nothing leaves this Mac either way."
    static let replace = "Replace"
    static let keepCurrent = "Keep current"

    // MARK: Browser pages (Go, internal/oauthpage)

    static let pageOpenHeading = "Continue in Watchtower"
    static let pageOpenBody = "Watchtower is asking you to confirm Acme. You can close this tab."
    static let pageRefusedHeading = "This link does not work"
    static let pageRefusedBody = "The link is damaged or cut short."
    static let pageRefusedHint = "Ask your admin for a fresh link, or paste the connect code in Watchtower → Connections."
    static let pageNewerHeading = "This link needs a newer Watchtower"
    static let pageNewerBody = "Update Watchtower from its menu, then open the link again."

    // MARK: Connections overview: Companies zone

    static let connectionsTitle = "Connections"
    static let connectMenu = "Connect…"
    static let companiesTitle = "Companies"
    static let sourcesTitle = "Sources"
    static let companyCount = "3 of 5 services connected"
    static let companyMissing = "Not connected: Gmail and Calendar, Linear"
    static let connectRest = "Connect the rest"
    static let companyMDMLine = "Set up by your organization · nothing connected yet"
    static let connectAll = "Connect all"
    static let companyRelogin = "Atlassian: Re-login needed — Acme changed its app"
    static let relogin = "Re-login"
    static let companiesEmpty = "Using Watchtower at work? Connect with your company's link or code, "
        + "or set it up for your company."
    static let setUpForCompany = "Set up for my company"
    static let connectWithCode = "Connect with a company code"
    static let codePlaceholder = "Company code"
    static let codeInvalid = "That is not a Watchtower company code. Copy it again from the Slack app's About page "
        + "or from your admin."
    static let portBusy = "Company links cannot reach Watchtower: port 18551 is busy. Paste the company code here instead."
    static let companiesLoading = "Reading company setups…"
    static let companiesReadFailed = "Could not read the company setups: acme.json is damaged."
    static let setupInProgress = "Setup in progress: Acme, at Atlassian (step 4 of 8)."
    static let continueSetup = "Continue setup"
    static let attentionJira = "Jira · Re-login needed — Acme changed its app"
    static let reconnect = "Reconnect"

    // MARK: Account rows grouped by company

    static let groupAcmeGoogle = "Acme's Google project · example.com"
    static let groupOwnGoogle = "Your own Google project"
    static let groupOwnGoogleCaption = "Gmail and Calendar through a project you own"
    static let groupShared = "Watchtower's shared app"
    static let groupSharedGoogleCaption = "Calendar only"
    static let groupAcmeAtlassian = "Acme's Atlassian app · acme.atlassian.net"
    static let groupTokens = "API tokens"
    static let groupTokensCaption = "Sites connected with your own token"
    static let groupAcmeSlack = "Acme's Slack app · Watchtower (A0ACME)"
    static let groupAcmeLinear = "Acme's Linear app"
    static let groupSharedLinear = "Watchtower's Linear app"
    static let groupAcmeMicrosoft = "Acme's Microsoft 365 app · tenant 0000-acme"
    static let groupSharedMicrosoft = "Watchtower's Microsoft app"
    static let groupUnknown = "Other accounts"
    static let groupUnknownCaption = "Signed in through an app this Watchtower no longer knows"
    static let accountsTitle = "Accounts"
    static let addAccountTitle = "Add an account"
    static let googleReuseCaption = "Reusing keeps the client and its id; nothing new is created."
    static let syncing = "Syncing · last sync 3 min ago"
    static let sharedSyncing = "Syncing through the shared app · last sync 3 min ago"
    static let rowNotConnected = "Not connected"
    static let reloginChanged = "Re-login needed — Acme changed its app"
    static let reloginNewLink = "Re-login needed — your company changed its app; open the new link"
    static let reloginUntied = "Re-login needed — open your company's link"
    static let pasteCode = "Paste a company code"
    static let stoppedByPolicy = "Stopped by your organization — data kept"
    static let tokenTag = "API token"
    static let sharedTag = "Shared app"

    // MARK: Banners (§5 of the parent)

    static let googleBannerTitle = "Gmail is leaving Watchtower's shared Google app"
    static let googleBannerBody = "bob@example.org keeps syncing Gmail until Google stops the old sign-in. Move Gmail to "
        + "your company's or your own Google project; Calendar stays on the shared app."
    static let atlassianBannerTitle = "Watchtower's shared Atlassian app is retired"
    static let atlassianBannerBody = "Your company needs its own Atlassian app — ask your admin or set it up. "
        + "Sign old.atlassian.net in again through your company's app or with an API token."
    static let useOwnGoogle = "Use my own Google project"
    static let connectTokenButton = "Connect with an API token"

    // MARK: Google detail

    static let googleTitle = "Google"
    static let googleEmpty = "Calendar connects through Watchtower's app. Gmail needs a Google project: your "
        + "company's (ask your admin for the link) or your own."
    static let connectCalendar = "Connect Google Calendar"
    static let googleLoading = "Reading Google accounts…"
    static let googleReadFailed = "Could not read Google accounts: database is locked."
    static let ownGoogleLocked = "Your organization does not allow own Google projects. Ask IT for your company's link."

    // MARK: Jira detail

    static let jiraTitle = "Jira"
    static let jiraEmpty = "Your company has no Atlassian app in Watchtower yet. Connect with your own API token, "
        + "or ask your admin for the company link."
    static let connectCompanyAtlassian = "Connect with Acme's Atlassian app"
    static let tokenDead = "The API token stopped working (expired or revoked) — paste a new one"
    static let tokenLease = "Its data stays. If no new token comes, the 30-day rule deletes it on Dec 18, "
        + "with a notice 72 hours before the 30-day mark."
    static let pasteNewToken = "Paste a new token"
    static let tokenLocked = "Your organization does not allow Atlassian API tokens. Token sites stop syncing "
        + "and keep their data."
    static let jiraLoading = "Reading Jira sites…"
    static let jiraReadFailed = "Could not read Jira sites: database is locked."

    // MARK: Use my own Google project (sheet, §4)

    static let ownTitle = "Use my own Google project"
    static let ownIntro = "Gmail and Calendar through a Google Cloud project you own. About ten minutes, once."
    static let ownGuide = [
        "Create a project",
        "Turn on the Gmail API and the Google Calendar API",
        "OAuth consent screen: user type External, and add yourself as a test user",
        "Publish the app to production. Google calls it unverified; that is expected for your own project",
        "Credentials → Create OAuth client → Desktop app, then download its JSON"
    ]
    static let ownUnverifiedNote = "The first sign-in shows “Google hasn't verified this app”. Choose Advanced → "
        + "Go to your project: it is your own."
    static let ownDoneTitle = "Connected bob@example.org through your own project"
    static let ownDoneBody = "The first sync starts now."
    static let ownWeeklyNote = "Google asks a project like this to sign in again every 7 days. "
        + "Watchtower reminds you when it is time."

    // MARK: Connect with an API token (sheet, §4b)

    static let tokenTitle = "Connect Jira with an API token"
    static let tokenIntro = "For a person whose company has no Atlassian app yet, or who prefers a token. "
        + "The token stays on this Mac."
    static let tokenStep1 = "1. Create a scoped API token"
    static let tokenStep1Help = "On your Atlassian account's Security page, create an API token with scopes: the Jira "
        + "scopes Watchtower lists, and the Confluence ones if you use Confluence."
    static let openAtlassianTokens = "Open Atlassian's token page"
    static let tokenStep2 = "2. Fill in"
    static let atlassianEmail = "Atlassian email"
    static let site = "Site"
    static let apiToken = "API token"
    static let scopedHint = "A token without scopes works too, but a scoped one can read only what Watchtower needs."
    static let tokenChecking = "Checking the token with acme.atlassian.net…"
    static let tokenUnauthorized = "Atlassian did not accept this email and token. Check both, or create a new token."
    static let tokenMissingScope = "This token lacks read:jira-work — create one with the listed scopes."
    static let tokenNotCloud = "acme.example.com is not an Atlassian Cloud site. Enter the address you open Jira at, "
        + "like acme.atlassian.net."
    static let tokenNetwork = "Could not reach acme.atlassian.net: the request timed out. Nothing was saved."
    static let tokenDoneTitle = "Connected to acme.atlassian.net as alice@example.com"
    static let tokenDoneBody = "The first sync starts now."
    static let tokenReplaceTitle = "Paste a new token for acme.atlassian.net"
    static let tokenReplaceIntro = "The old token stopped working. Your data was kept; a new token picks up where the "
        + "sync stopped."
    static let saveToken = "Save token"

    // MARK: Settings → Privacy → Organization policy

    static let policyTitle = "Organization policy"
    static let policyFooter = "Your organization sets these through a configuration profile. They outvote your own "
        + "settings, which come back when the profile is removed."
    static let blockedTitle = "Blocked by your organization"
    static let blockedBody = "Your organization's policy does not allow this source. Existing accounts stop syncing "
        + "and keep their data; nothing new can be connected."
}
