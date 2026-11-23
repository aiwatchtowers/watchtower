import Foundation

/// A field **We already have one** asks for (company screens spec §2.4).
package struct CompanyFieldSpec: Equatable, Sendable, Identifiable {
    package enum Key: String, Sendable {
        case slackAppID, clientID, clientSecret, tenantID
    }

    package let key: Key
    package let label: String
    package let secure: Bool
    package let help: String?

    package var id: Key { key }
}

/// Per vendor, the words and links of the setup wizard's vendor steps
/// (company screens spec §2.3–§2.11, §9): the Services row, the guide lines
/// with their deep links, the "Not sure?" hints, the Publish "not used" /
/// "skipped" lines, what **We already have one** asks, and who needs admin
/// rights. Every string is pinned by `CompanyVendorGuideTests`.
package enum CompanyVendorGuide {
    /// The rail and the summary name of each vendor.
    package static func name(_ v: CompanyVendor) -> String {
        switch v {
        case .slack: "Slack"
        case .google: "Google"
        case .atlassian: "Atlassian"
        case .linear: "Linear"
        case .microsoft: "Microsoft 365"
        }
    }

    /// The host every deep link of the vendor's guide opens.
    package static func host(_ v: CompanyVendor) -> String {
        switch v {
        case .slack: "api.slack.com"
        case .google: "console.cloud.google.com"
        case .atlassian: "developer.atlassian.com"
        case .linear: "linear.app"
        case .microsoft: "entra.microsoft.com"
        }
    }

    // MARK: Services step (§2.3)

    package static let servicesTitle = "What does your company use?"
    package static let servicesBody = "Tick what your company has. Each ticked service gets its own step; the link deny list "
        + "and Publish always follow."
    package static let foundOnMac = "Found on this Mac"
    package static let mcpNote = "Use something else (Notion, GitHub, a CRM…)? Connect it yourself in Connections → "
        + "Quick Connections (MCP connectors)."
    package static let openQuickConnections = "Open Quick Connections"
    /// The Connections service **Open Quick Connections** selects (`ConnectionService.quickConnections`).
    package static let quickConnectionsService = "quickConnections"

    package static func servicesRow(_ v: CompanyVendor) -> (title: String, detail: String) {
        switch v {
        case .slack: ("Slack", "Messages, digests and the Inbox")
        case .google: ("Google Workspace — Gmail and Calendar", "Mail and calendar through your company's Google project")
        case .atlassian: ("Atlassian — Jira and Confluence", "Issues and pages through your company's Atlassian app")
        case .linear: ("Linear", "Issues through your company's Linear app")
        case .microsoft: ("Microsoft 365 — Outlook", "Mail through your company's Entra app")
        }
    }

    // MARK: Guides

    /// The numbered guide of **Create new**, each line with its deep link
    /// (nil: the line is done in Watchtower or has a Copy button instead).
    package static func guideLines(_ v: CompanyVendor) -> [(text: String, link: URL?)] {
        switch v {
        case .slack:
            // Slack spec §3.2's token form, unchanged (SlackAppSetupModel's words).
            [("1. Generate a configuration token", url("https://api.slack.com/apps")), ("2. Paste it here", nil)]
        case .google:
            [("Create a project", url("https://console.cloud.google.com/projectcreate")),
             ("Turn on the Gmail API and the Google Calendar API", url("https://console.cloud.google.com/apis/library")),
             ("OAuth consent screen: user type Internal", url("https://console.cloud.google.com/apis/credentials/consent")),
             ("Credentials → Create OAuth client → Desktop app, then download its JSON",
              url("https://console.cloud.google.com/apis/credentials"))]
        case .atlassian:
            [("Create an OAuth 2.0 integration", url("https://developer.atlassian.com/console/myapps/")),
             ("Permissions: add the Jira API and the Confluence API with Watchtower's scopes, and report:personal-data", nil),
             ("Authorization: add Watchtower's callback URLs", nil),
             ("Distribution: turn Sharing on and answer Yes to “Does your app store personal data?”", nil),
             ("Add a second admin as an owner, so the app outlives one person", nil)]
        case .linear:
            [("Settings → API → OAuth applications → New application", url("https://linear.app/settings/api/applications/new")),
             ("Callback URL: paste Watchtower's", nil)]
        case .microsoft:
            [("App registrations → New registration: Accounts in this organizational directory only",
              url("https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")),
             ("Platform: Mobile and desktop applications, redirect URI http://localhost", nil),
             ("API permissions: add the Outlook permissions, then Grant admin consent", nil)]
        }
    }

    /// The Copy button a guide line carries, by line index.
    package static func guideCopyButtons(_ v: CompanyVendor) -> [Int: String] {
        switch v {
        case .slack, .google: [:]
        case .atlassian: [1: "Copy scopes", 2: "Copy callback URLs"]
        case .linear: [1: "Copy callback URL"]
        case .microsoft: [2: "Copy permissions"]
        }
    }

    /// What a guide line's Copy button copies (scopes, callback URLs,
    /// permissions). Empty until spike S1 settles the values (plan Task 2):
    /// the button stays disabled rather than copy nothing.
    package static func guideCopyText(_: CompanyVendor, line _: Int) -> String { "" }

    /// The caption under a public client's fields (no secret).
    package static func fieldsNote(_ v: CompanyVendor) -> String? {
        switch v {
        case .linear: "No secret: Watchtower signs in with PKCE."
        case .microsoft: "No secret: Watchtower signs in with PKCE against your tenant."
        case .slack, .google, .atlassian: nil
        }
    }

    // MARK: Existing apps first (§2.4)

    package static func notSure(_ v: CompanyVendor) -> String {
        switch v {
        case .slack: "Not sure? In Slack, open Apps and search for Watchtower. If it is there, someone already created it."
        case .google: "Not sure? Look in Google Cloud Console → APIs & Services → Credentials, under OAuth 2.0 Client IDs."
        case .atlassian: "Not sure? Look in the Atlassian developer console → My apps."
        case .linear: "Not sure? Look in Linear → Settings → API → OAuth applications."
        case .microsoft: "Not sure? Look in the Microsoft Entra admin center → App registrations → All applications."
        }
    }

    package static func alreadyHaveFields(_ v: CompanyVendor) -> [CompanyFieldSpec] {
        let clientID = CompanyFieldSpec(key: .clientID, label: "Client ID", secure: false, help: nil)
        let secret = CompanyFieldSpec(key: .clientSecret, label: "Client secret", secure: true, help: nil)
        switch v {
        case .slack:
            // The Client ID too: Go adopts an app no account here is on only with it.
            return [CompanyFieldSpec(key: .slackAppID, label: "App ID", secure: false,
                                     help: "Starts with A, like A0123ABCD: api.slack.com/apps → your app → Basic "
                                         + "Information. A link to the app works too."),
                    CompanyFieldSpec(key: .clientID, label: "Client ID", secure: false,
                                     help: "Needed when no account on this Mac uses the app yet: Basic Information → App "
                                         + "Credentials on api.slack.com.")]
        case .google, .atlassian:
            return [clientID, secret]
        case .linear:
            return [clientID]
        case .microsoft:
            return [CompanyFieldSpec(key: .clientID, label: "Application (client) ID", secure: false, help: nil),
                    CompanyFieldSpec(key: .tenantID, label: "Directory (tenant) ID", secure: false, help: nil)]
        }
    }

    /// "Looking for <vendor> apps this Mac already knows…"
    package static func looking(_ v: CompanyVendor) -> String {
        "Looking for \(name(v)) apps this Mac already knows…"
    }

    /// The nothing-found line (the Slack step's first open has none).
    package static func notFound(_ v: CompanyVendor) -> String? {
        v == .slack ? nil : "No \(name(v)) client found on this Mac."
    }

    /// Under the found apps.
    package static func reuseCaption(_ v: CompanyVendor) -> String {
        v == .slack
            ? "Reusing keeps the app and its ids; nothing new is created. A configuration token is still needed to check "
            + "and update its settings."
            : "Reusing keeps the client and its id; nothing new is created."
    }

    // MARK: Publish summary (§2.3, §2.10)

    /// What a service the company does not set up means for colleagues.
    package static func notUsedLine(_ v: CompanyVendor, skipped: Bool) -> String {
        let word = skipped ? "skipped" : "not used"
        let meaning = switch v {
        case .slack: "no Slack page carries the link"
        case .google: "colleagues can connect Google Calendar; Gmail needs their own Google project"
        case .atlassian: "colleagues connect Jira with their own API token"
        case .linear: "colleagues use Watchtower's shared Linear app"
        case .microsoft: "colleagues use Watchtower's shared Microsoft app, which your tenant may ask an admin to approve"
        }
        return "\(name(v)) · \(word): \(meaning)"
    }

    // MARK: You may not be an admin (§2.11, S3)

    /// What needs real admin rights, and what to do without them.
    package static func adminNeeds(_ v: CompanyVendor) -> String {
        switch v {
        case .slack:
            "Creating the app needs a workspace admin only where your workspace restricts app creation; where installs "
                + "need approval, Slack sends your admin a request."
        case .google:
            "An Internal app needs the project inside your company's Google Cloud organization; creating one there "
                + "needs the Project Creator role. Without it, your Google Workspace admin creates the project."
        case .atlassian:
            "No admin rights needed: any Atlassian account can create the app. An organization that blocks "
                + "user-installed apps may refuse the sign-in."
        case .linear:
            "Creating the OAuth application needs a Linear workspace admin. Where your workspace asks for app "
                + "approvals, the sign-in waits until an admin approves Watchtower."
        case .microsoft:
            "Grant admin consent needs a tenant admin (Cloud Application Administrator or above). Registering the app "
                + "needs one only if your tenant turned app registration off."
        }
    }

    private static func url(_ text: String) -> URL? { URL(string: text) }
}
