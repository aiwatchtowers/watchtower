import Foundation

/// Design-only string table of the Slack Full / Live screens spec
/// (`docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md`).
/// The implementation moves each group into the view model the spec names
/// (`SlackModePresentation`, `SlackAppSetupModel`, `SlackConnectFlowModel`,
/// `FeatureReadiness`) and pins it there; `SlackFullLiveMockCopyTests` pins
/// this table so the mockups and the spec cannot drift apart. Sample data
/// only: `acme`, made-up ids.
enum SlackFullLiveMockCopy {
    // MARK: Connections → Slack: the mode

    static let modeTitle = "Slack mode"
    static let chipFull = "Full"
    static let chipFullLive = "Full · Live on"
    static let chipLive = "Live"
    static let chipOff = "Off"
    static let chipShared = "Shared app"

    static let summaryFull = "Synced on this Mac through your workspace's own Slack app. Every feature works."
    static let summaryFullLive = "Synced on this Mac through your workspace's own Slack app. "
        + "Chats also read Slack through Live for what is not synced."
    static let summaryLive = "Chats and automations read Slack through your Claude or ChatGPT connector. "
        + "Nothing is synced, so digests, the Inbox, tracks and people need your workspace's app."
    static let summaryOff = "Slack is not connected. Connect your workspace's app to sync, or turn on the Slack "
        + "connector in your Claude or ChatGPT account to ask about Slack in Chats."
    static let summaryShared = "acme syncs through Watchtower's old shared Slack app until Slack turns it off."

    // MARK: Live rows

    static let liveTitle = "Live"
    static let providerClaude = "Claude"
    static let providerCodex = "ChatGPT (Codex)"
    static let liveOn = "On · acme"
    static let liveOnTeamID = "On · T0ACME"
    static let liveOnUnidentified = "On · workspace not identified"
    static let liveNotConnected = "Not connected"
    static let liveNeedsAdmin = "Waiting for your Slack admin"
    static let liveNoPlan = "Not in your plan"
    static let liveUnavailable = "Unavailable"
    static let reasonConnectorsOff = "Connectors are off in Watchtower's chat settings."
    static let reasonCLIMissing = "Codex is not installed on this Mac."
    static let reasonDefault = "Turn on the Slack connector in your Claude or ChatGPT account."
    static let reasonNeedsAdmin = "Your workspace admin must approve the connector."
    static let reasonNoPlan = "Your plan has no Slack connector."
    static let reasonUnidentified = "Chats use it; Watchtower could not tell which workspace it reads."
    static let checkedJustNow = "checked just now"
    static let checked12Min = "checked 12 min ago"
    static let checked2H = "checked 2 h ago"
    static let checked5H = "checked 5 h ago"
    static let notCheckedYet = "Live has not been checked yet."
    static let checkAgain = "Check again"
    static let checking = "Checking Live… this takes a few seconds."
    static let loading = "Reading the Live status…"
    static let probeFailed = "The Claude Live Slack check failed: the watchtower command did not answer in 150 seconds."
    static let readFailed = "Could not read the Live Slack status: database is locked."
    static let tryAgain = "Try again"

    // MARK: Connect your workspace's app

    static let connectTitle = "Connect your workspace's app"
    static let connectCaption = "Open Watchtower's app in Slack, go to its About tab and click the connect link. "
        + "No clickable link? Paste the link or the connect code here."
    static let pastePlaceholder = "Connect link or code"
    static let connect = "Connect"
    static let pasteInvalid = "That is not a Watchtower connect link or code. Copy it again from the app's About tab in Slack."
    static let portBusy = "The connect link cannot reach Watchtower: port 18551 is busy. "
        + "Quit the app holding port 18551, then open Connections → Slack again to retry."
    static let orgTitle = "Set up by your organization"
    static let orgRow = "Workspace T0ACME"
    static let noAppYet = "No Watchtower app in your workspace yet?"
    static let setUpForCompany = "Set up for my company"

    // MARK: The admin's unfinished setup (Connections → Slack)

    static let recordInstall = "Setup is not finished: Watchtower's app exists in acme, but you have not connected yet."
    static let continueSetup = "Continue setup"
    static let recordApproval = "Waiting for your admin's approval in acme. Check again once they approve."
    static let recordLinkMissing = "The app's About page has no connect link yet, so colleagues cannot connect."
    static let addLink = "Add the link to the app"

    // MARK: The retired shared app (D11)

    static let sharedTitle = "Watchtower's shared Slack app is retiring"
    static let sharedBody = "acme still syncs through it until Slack turns it off. Move to Full with your workspace's "
        + "own app, or use Live through your Claude or ChatGPT account."
    static let pasteALink = "Paste a connect link"

    // MARK: Workspaces list

    static let workspacesTitle = "Workspaces"
    static let accountFull = "Syncing · last sync 3 min ago"
    static let connectAnother = "Connect another workspace…"
    static let accountShared = "Syncing through the shared app · last sync 3 min ago"

    // MARK: Set up for my company (sheet)

    static let setupTitle = "Set up Watchtower for your company"
    static let setupIntro = "Creates Watchtower's app in your Slack workspace from our manifest. Colleagues then "
        + "connect from the app's About page in Slack; nothing depends on this Mac afterwards."
    static let setupStep1 = "1. Generate a configuration token"
    static let setupStep1Help = "On Slack's app page, under Your App Configuration Tokens, press Generate Token "
        + "for your workspace and copy the access token."
    static let openTokenPage = "Open Slack's token page"
    static let setupStep2 = "2. Paste it here"
    static let tokenPlaceholder = "Configuration token"
    static let tokenNote = "Used once for this setup and never stored."
    static let createApp = "Create the app"
    static let cancel = "Cancel"
    static let close = "Close"
    static let done = "Done"
    static let progressSteps = [
        "Checking the token",
        "Creating the app",
        "Writing the connect link to its About page",
        "Connecting your Slack account"
    ]
    static let progressCaption = "Keep this window open. If it closes, continue from Connections → Slack; "
        + "the app is never created twice."
    static let successTitle = "Watchtower's app is ready in acme"
    static let successBody = "You are connected. Colleagues open Watchtower in Slack, go to About and click "
        + "the connect link."
    static let copyCode = "Copy connect code"
    static let badToken = "That token did not work: it has expired or is not a configuration token. "
        + "Generate a new one and paste it."
    static let notAllowed = "Your workspace does not let you create apps. Ask a workspace admin to run this setup."
    static let linkFailed = "The app works, but its About page has no connect link yet: the token expired before "
        + "the link was written. Paste a fresh token to add it."
    static let approval = "Waiting for your admin's approval. Slack sent them a request to install Watchtower. "
        + "Check again once they approve; this window can close."

    // MARK: Add the link to the app (sheet)

    static let addLinkTitle = "Add the connect link to the app"
    static let addLinkIntro = "Writes the connect link and code into the About page of Watchtower's app in acme. "
        + "Needs a fresh configuration token."
    static let addLinkAction = "Add the link"
    static let addLinkBusy = "Writing the link…"
    static let addLinkDone = "The connect link is on the app's About page."

    // MARK: Connect from a link or code

    static let confirmTitle = "Connect a Slack workspace?"
    static let confirmBody = "A link asks Watchtower to connect workspace T0ACME through app 1111.2222. "
        + "Connect only if you opened this link yourself."
    static let browserWait = "Finish in your browser: Slack asks you to allow Watchtower."
    static let browserNote = "If Slack says your admin must approve the app, connect again once they have."
    static let connectedTitle = "Connected to acme"
    static let connectedBody = "The first sync starts now. Digests and the Inbox fill in after it."
    static let teamMismatch = "Slack signed you in to a different workspace than the link names. Nothing was saved."
    static let denied = "You did not allow Watchtower in Slack. Nothing was saved."
    static let startAgain = "Start again"

    // MARK: needsFullSlack (every Slack-dependent screen)

    static let needsFullLine = "Needs your workspace's Slack app. Live answers in Chats only."
    static let needsFullAction = "Connect workspace app"
    static let knowledgeNote = "Slack is not in Knowledge: Live answers are not kept. "
        + "Connect your workspace's app to add synced Slack."

    // MARK: Add to Knowledge (shipped in plan A)

    static let keepTitle = "Add to Knowledge"
    static let keepReason = "Built on Live Slack answers, which are not kept"

    // MARK: Plan B additions (asks #1425, #1426): admin note, adopt, onboarding

    static let copyAdminNote = "Copy a note for your admin"
    static let adminNoteCopied = "Copied. Send it to a workspace admin."
    static let adminNote = "Please set up Watchtower for acme in Slack: "
        + "https://github.com/aiwatchtowers/watchtower/blob/main/docs/guide/features/slack-full.md"
        + "#set-up-slack-for-your-company"
    static let adoptTitle = "Watchtower's app already exists in acme"
    static let adoptPKCEWarning = "Watchtower turns on PKCE sign-in for this app, which can be turned off "
        + "only by Slack support; Slack may ask colleagues already connected to allow Watchtower again."
    static let adoptBody = "Update it to the current version: Watchtower adds the connect link to its About page "
        + "and the sign-in settings it needs. " + adoptPKCEWarning
    static let adoptAction = "Update the app"
    static let adoptAppIDLabel = "App ID"
    static let adoptAppIDHelp = "Find it on the app's Basic Information page at api.slack.com/apps."
    static let notCollaborator = "Your token cannot change this app. Ask one of its collaborators "
        + "(listed on its Collaborators page) to run this setup."
    static let onboardingTitle = "Connect Slack"
    static let onboardingCaption = "Watchtower connects through your workspace's own Slack app. "
        + "Open Watchtower in Slack, go to its About tab and click the connect link, or paste the link or code here."
    static let onboardingLiveHint = "No app in your workspace? Chats can still read Slack through Live "
        + "in your Claude or ChatGPT account."
    static let skip = "Skip"

    // MARK: Plan B Task 13 review: the lost create, the App ID check, a refusal

    static let pendingBody = "Slack did not answer when Watchtower asked it to create the app in acme, so the app may "
        + "exist. Look for “Watchtower” on api.slack.com/apps. If it is there, enter its App ID and Client ID from its "
        + "Basic Information page, then paste a fresh configuration token to add the connect link; if not, start again."
    static let confirmClear = "Watchtower may have created the app already. Check Slack's app page first: if “Watchtower” "
        + "is there, enter its ids and use it. Start again only if it is not there, or the workspace gets a second "
        + "Watchtower app."
    static let confirmClearAction = "Nothing there: start again"
    static let clientIDLabel = "Client ID"
    static let openAppsPage = "Open Slack's app page"
    static let pendingStartAgain = "Start again"
    static let pendingUseApp = "Use this app"
    static let recordPending = "Setup is not finished: Slack did not confirm Watchtower's app in acme. "
        + "Check api.slack.com/apps before going on."
    static let adoptConfirm = "App A0ACME is called “Watchtower”. Update it only if it is your workspace's Watchtower app. "
        + adoptPKCEWarning
    static let appIDFormat = "That is not an App ID: it starts with A."
    static let busy = "Another setup is already running on this Mac. Try again once it has finished."
}
