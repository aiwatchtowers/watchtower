import Foundation

// MARK: - Inputs

/// A stored company as the Connections tab needs it (`company list --json`).
package struct CompanyRef: Equatable, Sendable, Identifiable {
    package var id: String { slug }
    package let slug: String
    package let name: String
    /// The MDM bundle (`forced`): the card says so and Connect all is prominent.
    package let forced: Bool
    /// A personal bundle is the person's own Google project, not a company.
    package let personal: Bool
    /// The vendor blocks the bundle carries → what identifies each app in a
    /// group caption: Google's domain, Atlassian's site, the Slack app's
    /// "<name> (<app id>)", Microsoft's tenant id; "" when nothing does.
    package let vendors: [CompanyVendor: String]

    package init(slug: String, name: String, forced: Bool = false, personal: Bool = false, vendors: [CompanyVendor: String]) {
        self.slug = slug
        self.name = name
        self.forced = forced
        self.personal = personal
        self.vendors = vendors
    }
}

/// A company file `company list --json` could not read.
package struct CompanyFileError: Equatable, Sendable {
    package let file: String
    package let error: String

    package init(file: String, error: String) {
        self.file = file
        self.error = error
    }
}

/// The wizard's draft as the Companies zone shows it; nil = no draft.
package enum CompanySetupDraftRef: Equatable, Sendable {
    /// `index` is the current step's zero-based place among `count` steps.
    case inProgress(company: String, step: String, index: Int, count: Int)
    case unreadable
}

/// One account row of a service detail, whatever its source: the columns
/// Go writes (`company_slug`, `auth_kind`, `status`, `error`) and the shared
/// app flag the CLI's `--json` reports (`shared_gmail`, `shared_atlassian`,
/// Slack's `shared_app`).
package struct AccountRef: Equatable, Sendable, Identifiable {
    package var id: String { "\(vendor.rawValue):\(accountID)" }
    package let vendor: CompanyVendor
    package let accountID: Int
    /// The row's name; for Jira the site host, which the Atlassian banner names.
    package let label: String
    package let companySlug: String
    package let status: String
    package let error: String
    package let authKind: String
    package let sharedApp: Bool

    package init(
        vendor: CompanyVendor,
        accountID: Int,
        label: String,
        companySlug: String,
        status: String,
        error: String,
        authKind: String = "oauth",
        sharedApp: Bool = false
    ) {
        self.vendor = vendor
        self.accountID = accountID
        self.label = label
        self.companySlug = companySlug
        self.status = status
        self.error = error
        self.authKind = authKind
        self.sharedApp = sharedApp
    }

    /// Removed or purged: it no longer connects its company's vendor.
    var isGone: Bool { status == "removed" || status == "purged" }
    package var isAPIToken: Bool { authKind == "api_token" }
    /// A Linear workspace connected with the person's own API key: no app of ours.
    var isAPIKey: Bool { authKind == "api_key" }
}

// MARK: - Outputs

/// The row over the cards while a wizard draft exists.
package struct SetupLine: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case continueSetup, setUpForCompany

        package var title: String {
            switch self {
            case .continueSetup: "Continue setup"
            case .setUpForCompany: CompaniesZoneState.Action.setUpForCompany.title
            }
        }
    }

    package let text: String
    package let action: Action
}

/// A stored company's card in the Companies zone (§4.1).
package struct CompanyCard: Equatable, Sendable, Identifiable {
    package enum Action: Equatable, Sendable {
        case connectRest, connectAll
        /// Runs the changed vendors' logins in a chain (§3.2).
        case relogin([CompanyVendor])

        package var title: String {
            switch self {
            case .connectRest: "Connect the rest"
            case .connectAll: "Connect all"
            case .relogin: RowStatus.Action.relogin.title
            }
        }

        /// MDM's Connect all is the overview's one prominent action.
        package var isProminent: Bool { self == .connectAll }
    }

    package var id: String { slug }
    package let slug: String
    package let name: String
    /// Shows **Managed by your organization**.
    package let managed: Bool
    package let line: String
    package let missingLine: String?
    /// In `Tone.error`: the vendors a Replace asks to log in again.
    package let problemLine: String?
    package let actions: [Action]
}

/// The Companies zone of the Connections overview (§4.1).
package struct CompaniesZoneState: Equatable, Sendable {
    package enum Body: Equatable, Sendable {
        case loading(String)
        /// No company could be read; **Try again**.
        case readFailed(String)
        /// No company and no draft: the one inviting line.
        case empty(String)
        case cards([CompanyCard])

        package var cards: [CompanyCard] {
            if case .cards(let cards) = self { return cards }
            return []
        }
    }

    /// The quiet buttons under the zone.
    package enum Action: Equatable, Sendable {
        case setUpForCompany, connectWithCode

        package var title: String {
            switch self {
            case .setUpForCompany: "Set up for my company"
            case .connectWithCode: "Connect with a company code"
            }
        }
    }

    /// The first row while a draft exists.
    package let setup: SetupLine?
    /// The warning line while the listener's port is busy; the code field opens with it.
    package let portBusy: String?
    package let body: Body
    /// A damaged company file beside readable ones.
    package let problem: String?
    package let actions: [Action]

    package var codeFieldOpen: Bool { portBusy != nil }
}

/// One row of an account group: an account, or a stored company's vendor
/// without one (§4.3 Not connected).
package enum AccountRow: Equatable, Sendable, Identifiable {
    case account(AccountRef)
    case notConnected(CompanyVendor)

    package var id: String {
        switch self {
        case .account(let a): a.id
        case .notConnected(let v): "not-connected:\(v.rawValue)"
        }
    }
}

/// A §4.2 section of a service detail.
package struct AccountGroup: Equatable, Sendable, Identifiable {
    package enum Kind: Equatable, Sendable {
        /// `apiKeys`: Linear workspaces on the person's own API key (never an app of ours).
        case company(String), ownProject, apiTokens, apiKeys, shared, other

        /// The policy key that stops this group's rows (§5.4, §6.5).
        package var lockKey: LockKey? {
            switch self {
            case .ownProject: .ownGoogleProject
            case .apiTokens: .atlassianAPIToken
            case .company, .apiKeys, .shared, .other: nil
            }
        }
    }

    package var id: String {
        switch kind {
        case .company(let slug): "company:\(slug)"
        case .ownProject: "own"
        case .apiTokens: "tokens"
        case .apiKeys: "keys"
        case .shared: "shared"
        case .other: "other"
        }
    }

    package let kind: Kind
    package let title: String
    package let caption: String?
    package let rows: [AccountRow]
}

/// A row's status line when it is not today's syncing line (§4.3).
package struct RowStatus: Equatable, Sendable {
    package enum Tone: Equatable, Sendable { case error, gray, secondary }

    package enum Action: Equatable, Sendable {
        case connect, relogin, pasteCode, pasteNewToken

        package var title: String {
            switch self {
            case .connect: "Connect"
            case .relogin: "Re-login"
            case .pasteCode: "Paste a company code"
            case .pasteNewToken: "Paste a new token"
            }
        }
    }

    package let text: String
    package let tone: Tone
    package let action: Action?
    /// §6.3's lease note under a dead token.
    package let note: String?

    package init(text: String, tone: Tone, action: Action?, note: String? = nil) {
        self.text = text
        self.tone = tone
        self.action = action
        self.note = note
    }

    /// Re-login and dead-token rows give the overview banner and the red
    /// badge; Not connected, stopped and hint rows do not (A5).
    package var needsAttention: Bool { tone == .error }
}

/// A retirement banner on a service detail (§7): `Tone.warning`, no
/// dismiss, never an attention item.
package struct CompanyBanner: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case useOwnGoogle, pasteCode, setUpForCompany, connectWithToken

        package var title: String {
            switch self {
            case .useOwnGoogle: "Use my own Google project"
            case .pasteCode: RowStatus.Action.pasteCode.title
            case .setUpForCompany: CompaniesZoneState.Action.setUpForCompany.title
            case .connectWithToken: "Connect with an API token"
            }
        }

        package var isQuiet: Bool { self == .pasteCode || self == .connectWithToken }
    }

    package let title: String
    package let body: String
    package let actions: [Action]
    /// The overview card's line for the same state.
    package let cardLine: String
}

/// A policy key that locks a way to connect (§5.4, §6.5).
package enum LockKey: Equatable, Hashable, Sendable {
    case ownGoogleProject, atlassianAPIToken
}

/// The lock card under a locked group; the view adds **Managed by your organization**.
package struct LockCard: Equatable, Sendable {
    package let text: String
    package let helpLabel: String
    package let helpURL: URL
}

// MARK: - Presentation

/// Connections, company setup screens spec §4: the Companies zone, the
/// accounts grouped by company, every §4.3 row status, §6.3's lease note,
/// §7's banners and §5.4/§6.5's lock cards. Pure; it owns every string and
/// the views only lay them out (`CompanyConnectionsPresentationTests`).
package enum CompanyConnectionsPresentation {
    // Account error codes Go writes (status 'error', never 'revoked'), and
    // the PDR hint that leaves the status as it is.
    private static let codeChangedApp = "company_changed_app"
    private static let codeInvalidClient = "invalid_client"
    private static let codeUnknownClient = "unknown_client"
    private static let codeAPITokenDead = "api_token_dead"
    private static let codePDRScopeMissing = "pdr_scope_missing"
    private static let draftFile = "draft.json"

    package static let companiesTitle = "Companies"
    package static let companiesLoading = "Reading company setups…"
    package static let companiesEmpty = "Using Watchtower at work? Connect with your company's link or code, "
        + "or set it up for your company."
    package static let portBusyLine = "Company links cannot reach Watchtower: port 18551 is busy. "
        + "Paste the company code here instead."
    package static let codePlaceholder = "Company code"
    package static let codeInvalid = "That is not a Watchtower company code. Copy it again from the Slack app's "
        + "About page or from your admin."
    package static let connect = "Connect"
    package static let tryAgain = "Try again"
    private static let readFailedPrefix = "Could not read the company setups: "
    package static let draftUnreadable = "Your unfinished setup could not be read — start again"

    package static let groupOwnGoogle = "Your own Google project"
    package static let groupOwnGoogleCaption = "Gmail and Calendar through a project you own"
    package static let groupShared = "Watchtower's shared app"
    package static let groupSharedGoogleCaption = "Calendar only"
    package static let groupSharedLinear = "Watchtower's Linear app"
    package static let groupSharedMicrosoft = "Watchtower's Microsoft app"
    package static let groupTokens = "API tokens"
    package static let groupTokensCaption = "Sites connected with your own token"
    package static let groupKeys = "API keys"
    package static let groupKeysCaption = "Workspaces connected with your own API key"
    package static let keyTag = "API key"
    package static let groupUnknown = "Other accounts"
    package static let groupUnknownCaption = "Signed in through an app this Watchtower no longer knows"
    /// The section under the groups that adds an account (and holds the last command's error).
    package static let addAccountTitle = "Add an account"
    package static let tokenTag = "API token"
    package static let sharedTag = "Shared app"

    package static let rowNotConnected = "Not connected"
    package static let reloginNewLink = "Re-login needed — your company changed its app; open the new link"
    package static let reloginUntied = "Re-login needed — open your company's link"
    package static let pdrScopeMissing = "Re-login to finish the setup"
    package static let stoppedByPolicyLine = "Stopped by your organization — data kept"
    package static let tokenDead = "The API token stopped working (expired or revoked) — paste a new one"

    package static let googleBannerTitle = "Gmail is leaving Watchtower's shared Google app"
    package static let googleBannerCardLine = "Gmail on the shared app"
    package static let atlassianBannerTitle = "Watchtower's shared Atlassian app is retired"
    package static let atlassianBannerCardLine = "Shared app retired — sign in again"

    package static let ownGoogleLocked = "Your organization does not allow own Google projects. Ask IT for your company's link."
    package static let tokenLocked = "Your organization does not allow Atlassian API tokens. Token sites stop syncing "
        + "and keep their data."

    /// A company card while its chain waits on a vendor (§3.2, A10).
    package static func connecting(_ vendor: CompanyVendor) -> String {
        "Connecting… \(vendorName(vendor))"
    }

    /// What identifies a company's Slack app in its group caption, from the
    /// Slack setup record that holds the bundle's client id.
    package static func slackAppDetail(appID: String) -> String {
        "Watchtower (\(appID))"
    }

    package static func reloginChanged(_ company: String) -> String {
        "Re-login needed — \(company) changed its app"
    }

    package static func googleBannerBody(_ labels: [String]) -> String {
        "\(list(labels)) \(labels.count == 1 ? "keeps" : "keep") syncing Gmail until Google stops the old sign-in. "
            + "Move Gmail to your company's or your own Google project; Calendar stays on the shared app."
    }

    /// `token` false: the API token is not on offer (its lock, or a build without the sheet).
    package static func atlassianBannerBody(_ sites: [String], token: Bool = true) -> String {
        "Your company needs its own Atlassian app — ask your admin or set it up. "
            + "Sign \(list(sites)) in again through your company's app\(token ? " or with an API token" : "")."
    }

    package static func tokenLease(_ due: Date, zone: TimeZone) -> String {
        "Its data stays. If no new token comes, the 30-day rule deletes it on \(shortDay(due, zone: zone)), "
            + "with a notice 72 hours before."
    }

    package static let notConnectedStatus = RowStatus(text: rowNotConnected, tone: .gray, action: .connect)

    // MARK: Zone

    package static func zone(
        companies: [CompanyRef],
        errors: [CompanyFileError],
        draft: CompanySetupDraftRef?,
        accounts: [AccountRef],
        portBusy: Bool,
        loading: Bool,
        listError: String? = nil
    ) -> CompaniesZoneState {
        if loading {
            return CompaniesZoneState(setup: nil, portBusy: nil, body: .loading(companiesLoading), problem: nil, actions: [])
        }
        let busy = portBusy ? portBusyLine : nil
        // `company list` itself failed: never "no company" (review-rules, absent vs. error).
        if let listError {
            return CompaniesZoneState(setup: nil, portBusy: busy, body: .readFailed("\(readFailedPrefix)\(listError)."),
                                      problem: nil, actions: [])
        }
        let shown = sorted(companies.filter { !$0.personal })
        // The draft's read error is the draft's own state (`draft`), not a company file's.
        let damaged = errors.map(\.file).filter { $0 != draftFile }
        let problem = damaged.isEmpty ? nil
            : "\(readFailedPrefix)\(list(damaged)) \(damaged.count == 1 ? "is" : "are") damaged."
        let setup = draft.map(setupLine)
        // While a draft exists, Continue setup is the way into the wizard.
        let actions: [CompaniesZoneState.Action] = draft == nil ? [.setUpForCompany, .connectWithCode] : [.connectWithCode]

        if shown.isEmpty, let problem {
            return CompaniesZoneState(setup: setup, portBusy: busy, body: .readFailed(problem), problem: nil, actions: [])
        }
        if shown.isEmpty, setup == nil {
            return CompaniesZoneState(setup: nil, portBusy: busy, body: .empty(companiesEmpty), problem: nil, actions: actions)
        }
        let cards = shown.map { card($0, accounts: accounts) }
        return CompaniesZoneState(setup: setup, portBusy: busy, body: .cards(cards), problem: problem, actions: actions)
    }

    private static func setupLine(_ draft: CompanySetupDraftRef) -> SetupLine {
        switch draft {
        case .unreadable:
            return SetupLine(text: draftUnreadable, action: .setUpForCompany)
        case let .inProgress(company, step, index, count):
            let who = company.isEmpty ? "" : ": \(company)"
            return SetupLine(text: "Setup in progress\(who), at \(step) (step \(index + 1) of \(count)).",
                             action: .continueSetup)
        }
    }

    private static func card(_ company: CompanyRef, accounts: [AccountRef]) -> CompanyCard {
        let vendors = CompanyVendor.allCases.filter { company.vendors[$0] != nil }
        let tied = accounts.filter { $0.companySlug == company.slug }
        // Connected = an ok account, as `company inspect` counts it (the connect sheet's rows).
        let connected = vendors.filter { v in tied.contains { $0.vendor == v && $0.status == "ok" } }
        let changed = vendors.filter { v in
            tied.contains { $0.vendor == v && $0.status == "error" && $0.error == codeChangedApp }
        }
        // A Replace's vendor has its own Re-login, not Connect the rest.
        let missing = vendors.filter { !connected.contains($0) && !changed.contains($0) }
        let nothingYet = company.forced && connected.isEmpty

        let line = nothingYet ? "Set up by your organization · nothing connected yet"
            : "\(connected.count) of \(vendors.count) \(vendors.count == 1 ? "service" : "services") connected"
        let missingLine = missing.isEmpty || nothingYet ? nil
            : "Not connected: " + missing.map(serviceName).joined(separator: ", ")
        let problemLine = changed.isEmpty ? nil
            : "\(changed.map(vendorName).joined(separator: ", ")): \(reloginChanged(company.name))"
        var actions: [CompanyCard.Action] = []
        if !changed.isEmpty { actions.append(.relogin(changed)) }
        if !missing.isEmpty { actions.append(nothingYet ? .connectAll : .connectRest) }
        return CompanyCard(slug: company.slug, name: company.name, managed: company.forced, line: line,
                           missingLine: missingLine, problemLine: problemLine, actions: actions)
    }

    /// The managed company first, then by name.
    static func sorted(_ companies: [CompanyRef]) -> [CompanyRef] {
        companies.sorted {
            if $0.forced != $1.forced { return $0.forced }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.slug < $1.slug : order == .orderedAscending
        }
    }

    // MARK: Groups

    /// The §4.2 sections of `vendor`'s detail, in order: one per company,
    /// then (Google) your own project, (Jira) API tokens, the shared app,
    /// other accounts. An empty group is left out. `ownProject` says which
    /// untied Google account signs in through a project of the person's own
    /// (a legacy credentials file); an account tied to a personal bundle is
    /// one too.
    package static func groups(
        vendor: CompanyVendor,
        accounts: [AccountRef],
        companies: [CompanyRef],
        ownProject: (AccountRef) -> Bool
    ) -> [AccountGroup] {
        let mine = accounts.filter { $0.vendor == vendor }
        let stored = sorted(companies.filter { !$0.personal })
        let storedSlugs = Set(stored.map(\.slug))
        // A Linear API key is no company's app, whatever slug its row still carries.
        let ownKey = { (a: AccountRef) in vendor == .linear && a.isAPIKey }

        var groups: [AccountGroup] = stored.compactMap { company in
            let tied = mine.filter { $0.companySlug == company.slug && !ownKey($0) }
            var rows = tied.map(AccountRow.account)
            if company.vendors[vendor] != nil, !tied.contains(where: { !$0.isGone }) {
                rows.append(.notConnected(vendor))
            }
            guard !rows.isEmpty else { return nil }
            return AccountGroup(kind: .company(company.slug), title: company.name,
                                caption: companyCaption(company, vendor), rows: rows)
        }

        var own: [AccountRow] = [], tokens: [AccountRow] = [], keys: [AccountRow] = []
        var shared: [AccountRow] = [], other: [AccountRow] = []
        for a in mine where !storedSlugs.contains(a.companySlug) || ownKey(a) {
            if isOwnGoogleProject(a, companies: companies, ownProject: ownProject) {
                own.append(.account(a))
            } else if vendor == .atlassian, a.isAPIToken {
                tokens.append(.account(a))
            } else if ownKey(a) {
                // A personal key signs in through no app: never the shared app's group.
                keys.append(.account(a))
            } else if a.companySlug.isEmpty, a.sharedApp || a.error != codeUnknownClient {
                // The shared app's rows stay in its group until their Re-login (§4.2), even
                // once its retired client is unknown.
                shared.append(.account(a))
            } else {
                // Tied to a company no longer stored, or signed in through an unknown client.
                other.append(.account(a))
            }
        }
        if !own.isEmpty {
            groups.append(AccountGroup(kind: .ownProject, title: groupOwnGoogle, caption: groupOwnGoogleCaption, rows: own))
        }
        if !tokens.isEmpty {
            groups.append(AccountGroup(kind: .apiTokens, title: groupTokens, caption: groupTokensCaption, rows: tokens))
        }
        if !keys.isEmpty {
            groups.append(AccountGroup(kind: .apiKeys, title: groupKeys, caption: groupKeysCaption, rows: keys))
        }
        if !shared.isEmpty {
            let (title, caption) = sharedGroupTitle(vendor)
            groups.append(AccountGroup(kind: .shared, title: title, caption: caption, rows: shared))
        }
        if !other.isEmpty {
            groups.append(AccountGroup(kind: .other, title: groupUnknown, caption: groupUnknownCaption, rows: other))
        }
        return groups
    }

    /// A Google account on the person's own project (§4.2 group 2, the
    /// §5.4 lock): tied to a personal bundle, or untied and flagged by
    /// `ownProject` (Go's `own_project`, a legacy credentials file).
    package static func isOwnGoogleProject(
        _ a: AccountRef, companies: [CompanyRef], ownProject: (AccountRef) -> Bool
    ) -> Bool {
        guard a.vendor == .google else { return false }
        return companies.contains { $0.personal && $0.slug == a.companySlug } || (a.companySlug.isEmpty && ownProject(a))
    }

    /// "Acme's Google project · example.com".
    private static func companyCaption(_ company: CompanyRef, _ vendor: CompanyVendor) -> String {
        let app: String = switch vendor {
        case .slack: "Slack app"
        case .google: "Google project"
        case .atlassian: "Atlassian app"
        case .linear: "Linear app"
        case .microsoft: "Microsoft 365 app"
        }
        let raw = company.vendors[vendor] ?? ""
        let detail: String = switch vendor {
        case .atlassian: URL(string: raw)?.host ?? raw
        case .microsoft: raw.isEmpty ? "" : "tenant \(raw)"
        default: raw
        }
        return "\(company.name)'s \(app)" + (detail.isEmpty ? "" : " · \(detail)")
    }

    private static func sharedGroupTitle(_ vendor: CompanyVendor) -> (String, String?) {
        switch vendor {
        case .google: (groupShared, groupSharedGoogleCaption)
        case .linear: (groupSharedLinear, nil)
        case .microsoft: (groupSharedMicrosoft, nil)
        case .slack, .atlassian: (groupShared, nil)
        }
    }

    /// The outline tag of a row: an API-token site, or an account on a
    /// shared app that is retiring or retired.
    package static func tag(_ a: AccountRef) -> String? {
        if a.isAPIToken { return tokenTag }
        if a.isAPIKey { return keyTag }
        return a.sharedApp ? sharedTag : nil
    }

    /// The head of a syncing row's line ("… · last sync 3 min ago").
    package static func syncingLine(_ a: AccountRef) -> String {
        a.sharedApp ? "Syncing through the shared app" : "Syncing"
    }

    // MARK: Row status

    /// The row's §4.3 status, or nil for today's line. `purgeLease` is the
    /// day PURGE-01's lease would delete the account, set only while it
    /// counts (purge on, nothing scheduled yet); `stoppedByPolicy` is the
    /// row of a locked group (`AccountGroup.Kind.lockKey`).
    package static func rowStatus(
        _ a: AccountRef,
        purgeLease: Date?,
        companies: [CompanyRef],
        stoppedByPolicy: Bool = false,
        zone: TimeZone = .current
    ) -> RowStatus? {
        // A removed or purged row keeps today's line: its data is not kept.
        if stoppedByPolicy, !a.isGone {
            return RowStatus(text: stoppedByPolicyLine, tone: .gray, action: nil)
        }
        if a.error == codePDRScopeMissing, a.status == "ok" {
            return RowStatus(text: pdrScopeMissing, tone: .secondary, action: .relogin)
        }
        guard a.status == "error" else { return nil }
        switch a.error {
        case codeChangedApp, codeInvalidClient:
            // A Replace re-logs through the stored bundle's app for this vendor; without
            // one (no bundle, or the new one dropped the vendor) the new link is the way.
            if a.error == codeChangedApp,
               let company = companies.first(where: { !a.companySlug.isEmpty && $0.slug == a.companySlug }),
               company.vendors[a.vendor] != nil {
                return RowStatus(text: reloginChanged(company.name), tone: .error, action: .relogin)
            }
            return RowStatus(text: reloginNewLink, tone: .error, action: .pasteCode)
        case codeUnknownClient:
            return RowStatus(text: reloginUntied, tone: .error, action: .pasteCode)
        case codeAPITokenDead:
            return RowStatus(text: tokenDead, tone: .error, action: .pasteNewToken,
                             note: purgeLease.map { tokenLease($0, zone: zone) })
        default:
            return nil
        }
    }

    /// An API-token site's row offers **Paste a new token**: its token died,
    /// or it fails for another reason no §4.3 status names (a token site has
    /// no OAuth sign-in). A stopped, removed or purged row offers nothing.
    package static func offersNewToken(_ a: AccountRef, status: RowStatus?) -> Bool {
        guard a.isAPIToken else { return false }
        if let status { return status.action == .pasteNewToken }
        return a.status == "error" || a.status == "revoked"
    }

    // MARK: Banners and locks

    /// §7's banner over `vendor`'s detail while an account still runs on a
    /// retiring shared app; nil otherwise.
    package static func banner(_ vendor: CompanyVendor, accounts: [AccountRef], locks: Set<LockKey> = []) -> CompanyBanner? {
        // Google's banner names accounts that still sync Gmail; Atlassian's, every account that
        // must sign in again.
        let flagged = accounts.filter { a in
            a.vendor == vendor && a.sharedApp && !a.isGone && (vendor != .google || a.status == "ok")
        }
        let labels = flagged.map(\.label)
        guard !labels.isEmpty else { return nil }
        switch vendor {
        case .google:
            let actions: [CompanyBanner.Action] = locks.contains(.ownGoogleProject) ? [.pasteCode] : [.useOwnGoogle, .pasteCode]
            return CompanyBanner(title: googleBannerTitle, body: googleBannerBody(labels), actions: actions,
                                 cardLine: googleBannerCardLine)
        case .atlassian:
            let actions: [CompanyBanner.Action] = locks.contains(.atlassianAPIToken)
                ? [.setUpForCompany] : [.setUpForCompany, .connectWithToken]
            return CompanyBanner(title: atlassianBannerTitle,
                                 body: atlassianBannerBody(labels, token: !locks.contains(.atlassianAPIToken)), actions: actions,
                                 cardLine: atlassianBannerCardLine)
        case .slack, .linear, .microsoft:
            // Slack's shared-app banner is plan B's (`SlackModePresentation`).
            return nil
        }
    }

    package static func lockCard(_ key: LockKey) -> LockCard {
        let text = switch key {
        case .ownGoogleProject: ownGoogleLocked
        case .atlassianAPIToken: tokenLocked
        }
        return LockCard(text: text, helpLabel: ManagedPolicyHelp.label, helpURL: ManagedPolicyHelp.itGuideURL)
    }

    // MARK: Names

    /// What a company's card lists as not connected.
    package static func serviceName(_ v: CompanyVendor) -> String {
        switch v {
        case .slack: "Slack"
        case .google: "Gmail and Calendar"
        case .atlassian: "Jira and Confluence"
        case .linear: "Linear"
        case .microsoft: "Outlook"
        }
    }

    /// The vendor a Replace names ("Atlassian: Re-login needed — …").
    package static func vendorName(_ v: CompanyVendor) -> String {
        switch v {
        case .slack: "Slack"
        case .google: "Google"
        case .atlassian: "Atlassian"
        case .linear: "Linear"
        case .microsoft: "Microsoft 365"
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "Dec 18" in `zone`. UI text is English only.
    private static func shortDay(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
