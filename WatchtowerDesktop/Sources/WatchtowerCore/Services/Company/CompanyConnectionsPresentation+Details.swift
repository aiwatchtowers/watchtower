import Foundation

/// What a service detail's account list shows (company screens spec §4.2):
/// a spinner before the first read, a failed read (never "nothing
/// connected", review-rules absent vs. error), the empty state (§5.3, §6.4),
/// or the groups.
package enum AccountsListState: Equatable, Sendable {
    case loading(String)
    case readFailed(String)
    case empty(String)
    case groups([AccountGroup])
}

/// A button of a detail's empty state or its "Add an account" section.
package struct DetailAction: Equatable, Sendable, Identifiable {
    package enum Kind: Equatable, Sendable {
        /// Calendar through Watchtower's shared Google app (D11: no Gmail).
        case connectCalendar
        case useOwnGoogle
        case pasteCode
        case connectWithToken
        /// The vendor's sign-in through a stored company's app.
        case connectCompany(slug: String)
    }

    package enum Emphasis: Equatable, Sendable { case prominent, secondary, quiet }

    package var id: String {
        switch kind {
        case .connectCalendar: "calendar"
        case .useOwnGoogle: "own"
        case .pasteCode: "paste"
        case .connectWithToken: "token"
        case .connectCompany(let slug): "company:\(slug)"
        }
    }

    package let kind: Kind
    package let title: String
    package let emphasis: Emphasis
}

extension CompanyConnectionsPresentation {
    package static let accountsTitle = "Accounts"
    package static let googleTitle = "Google"
    package static let jiraTitle = "Jira"
    package static let googleLoading = "Reading Google accounts…"
    package static let jiraLoading = "Reading Jira sites…"
    package static let googleEmpty = "Calendar connects through Watchtower's app. Gmail needs a Google project: your "
        + "company's (ask your admin for the link) or your own."
    package static let jiraEmpty = "Your company has no Atlassian app in Watchtower yet. Connect with your own API token, "
        + "or ask your admin for the company link."
    /// §6.4 without the token (its lock, or a build without the token sheet).
    package static let jiraEmptyNoToken = "Your company has no Atlassian app in Watchtower yet. Ask your admin for the "
        + "company link."
    package static let notSyncing = "Not syncing"
    package static let dataDeleted = "Data deleted"
    package static let turnedOff = "Turned off"

    /// The section title of `vendor`'s empty state.
    package static func detailTitle(_ vendor: CompanyVendor) -> String {
        vendor == .google ? googleTitle : jiraTitle
    }

    package static let connectCalendar = "Connect Google Calendar"

    /// "Connect with Acme's Atlassian app".
    package static func connectCompanyApp(_ company: String, _ vendor: CompanyVendor) -> String {
        "Connect with \(company)'s \(vendorName(vendor)) app"
    }

    /// "Could not read Google accounts: database is locked."
    package static func readFailed(_ vendor: CompanyVendor, _ detail: String) -> String {
        let what = vendor == .atlassian ? "Jira sites" : "\(vendorName(vendor)) accounts"
        let end = detail.hasSuffix(".") ? "" : "."
        return "Could not read \(what): \(detail)\(end)"
    }

    /// The account list of `vendor`'s detail. `loaded` is false until the
    /// first read finished; `readError` is the last failed read, which with
    /// no account listed is the list's state — a stored company's Not
    /// connected row over unread accounts would claim what nobody knows.
    package static func accountsList(
        vendor: CompanyVendor,
        loaded: Bool,
        readError: String?,
        accounts: [AccountRef],
        groups: [AccountGroup],
        locks: Set<LockKey> = []
    ) -> AccountsListState {
        guard loaded else { return .loading(vendor == .google ? googleLoading : jiraLoading) }
        if let readError, accounts.isEmpty { return .readFailed(readFailed(vendor, readError)) }
        guard groups.isEmpty else { return .groups(groups) }
        if vendor == .google { return .empty(googleEmpty) }
        return .empty(locks.contains(.atlassianAPIToken) ? jiraEmptyNoToken : jiraEmpty)
    }

    /// The buttons under the list (`empty` false, "Add an account") or of
    /// the empty state (§5.3, §6.4). Google: Calendar on the shared app, the
    /// own project (gone under its lock, §5.4), a company code. Jira: each
    /// stored company's Atlassian app, the API token (gone under its lock,
    /// §6.5); a company code when no company app is offered.
    package static func detailActions(
        _ vendor: CompanyVendor,
        companies: [CompanyRef],
        empty: Bool,
        locks: Set<LockKey> = []
    ) -> [DetailAction] {
        let paste = DetailAction(kind: .pasteCode, title: RowStatus.Action.pasteCode.title, emphasis: .quiet)
        switch vendor {
        case .google:
            var actions = [DetailAction(kind: .connectCalendar, title: connectCalendar, emphasis: empty ? .prominent : .secondary)]
            if !locks.contains(.ownGoogleProject) {
                actions.append(DetailAction(kind: .useOwnGoogle, title: CompanyBanner.Action.useOwnGoogle.title,
                                            emphasis: .secondary))
            }
            return actions + [paste]
        case .atlassian:
            let companyApps = sorted(companies.filter { !$0.personal && $0.vendors[.atlassian] != nil }).map {
                DetailAction(kind: .connectCompany(slug: $0.slug), title: connectCompanyApp($0.name, .atlassian),
                             emphasis: .secondary)
            }
            var actions = companyApps
            if !locks.contains(.atlassianAPIToken) {
                actions.append(DetailAction(kind: .connectWithToken, title: CompanyBanner.Action.connectWithToken.title,
                                            emphasis: empty ? .prominent : .secondary))
            }
            if companyApps.isEmpty { actions.append(paste) }
            return actions
        case .slack, .linear, .microsoft:
            return []
        }
    }

    /// The head of a row's line when no §4.3 status speaks: syncing only for
    /// a healthy, enabled row.
    private static func rowHead(_ a: AccountRef, enabled: Bool) -> String {
        switch a.status {
        case "purged": dataDeleted
        case "ok": enabled ? syncingLine(a) : turnedOff
        default: enabled ? notSyncing : turnedOff
        }
    }

    /// A Google row's line: how it syncs and what it grants.
    package static func googleRowLine(_ a: AccountRef, calendar: Bool, gmail: Bool) -> String {
        let services: String = switch (calendar, gmail) {
        case (true, true): "Calendar and Gmail"
        case (true, false): "Calendar"
        case (false, true): "Gmail"
        case (false, false): "No service"
        }
        return "\(rowHead(a, enabled: true)) · \(services)"
    }

    /// A Jira row's line: how it syncs, the site when the title (a renamed
    /// label) does not say it, and who signed in.
    package static func jiraRowLine(_ a: AccountRef, title: String, enabled: Bool, email: String) -> String {
        let site = a.label == title ? "" : a.label
        return [rowHead(a, enabled: enabled), site, email].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A Gmail row on Watchtower's shared Google app that must sign in again
    /// (D11): its Re-login would ask the shared app for Gmail, which it no
    /// longer grants, so the row offers the move instead — your own project
    /// (the same address's row moves onto it), or a company code under the
    /// §5.4 lock. Nil for any other row (its Re-login works).
    package static func sharedGmailMove(_ a: AccountRef, locks: Set<LockKey>) -> CompanyBanner.Action? {
        guard a.vendor == .google, a.sharedApp, a.status != "ok", !a.isGone else { return nil }
        return locks.contains(.ownGoogleProject) ? .pasteCode : .useOwnGoogle
    }

    /// The policy locks in force: what the banners and add sections leave out.
    package static func locks(ownGoogleProjectAllowed: Bool, atlassianAPITokenAllowed: Bool) -> Set<LockKey> {
        var locks: Set<LockKey> = []
        if !ownGoogleProjectAllowed { locks.insert(.ownGoogleProject) }
        if !atlassianAPITokenAllowed { locks.insert(.atlassianAPIToken) }
        return locks
    }
}

/// The account flags of `google accounts --json` (`shared_gmail`,
/// `own_project`) and `jira accounts --json` (`shared_atlassian`): Go
/// decides them (it owns the client resolver and the own-project rule,
/// `company.IsOwnProject`), the Desktop only reads which account ids carry
/// them.
package enum SharedAppFlags {
    package static let googleArgs = ["google", "accounts", "--json"]
    package static let googleFlag = "shared_gmail"
    /// A Google account on a project the person owns (#1887 C4).
    package static let ownProjectFlag = "own_project"
    package static let jiraArgs = ["jira", "accounts", "--json"]
    package static let jiraFlag = "shared_atlassian"

    package struct DecodeError: Error, Equatable {}

    /// The ids of the array's rows whose `flag` is true.
    package static func accountIDs(_ data: Data, flag: String) throws -> Set<Int> {
        try accountIDs(data, flags: [flag])[flag] ?? []
    }

    /// Per flag, the ids of the array's rows where it is true.
    package static func accountIDs(_ data: Data, flags: [String]) throws -> [String: Set<Int>] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw DecodeError() }
        var ids: [String: Set<Int>] = Dictionary(uniqueKeysWithValues: flags.map { ($0, []) })
        for row in rows {
            guard let id = row["id"] as? Int else { throw DecodeError() }
            for flag in flags where row[flag] as? Bool == true { ids[flag, default: []].insert(id) }
        }
        return ids
    }

    /// `jira accounts --json`'s `purge_lease_at`: the day PURGE-01's lease
    /// would delete the account, present only while that lease counts (Go
    /// decides it with the daemon's own rule, §6.3).
    package static let jiraLeaseField = "purge_lease_at"

    /// The rows' `field` dates (RFC 3339) by account id; a row without one is left out.
    package static func dates(_ data: Data, field: String) throws -> [Int: Date] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw DecodeError() }
        let formatter = ISO8601DateFormatter()
        var out: [Int: Date] = [:]
        for row in rows {
            guard let id = row["id"] as? Int else { throw DecodeError() }
            guard let raw = row[field] as? String, !raw.isEmpty else { continue }
            guard let date = formatter.date(from: raw) else { throw DecodeError() }
            out[id] = date
        }
        return out
    }
}
