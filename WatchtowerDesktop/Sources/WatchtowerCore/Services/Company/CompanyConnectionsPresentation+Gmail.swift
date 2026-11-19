import Foundation

/// Where Email → Add Account → **Connect Gmail** goes (#1887 D11: the
/// shared Google app asks for Calendar only).
package enum GmailRoute: Equatable, Sendable {
    /// The Add Google Account sheet with its Gmail switch: a flavored build,
    /// whose baked client asks for Gmail itself.
    case sharedSheet
    /// The own Google project page in the Google detail (§5.2).
    case ownProjectPage
    /// The Google detail: a stored company's Google row (§5.3), or the empty
    /// state's company code while own projects are locked (§5.4).
    case googleDetail
}

/// The Add Google Account sheet's words (Calendar and, where the build's
/// client asks for it, Gmail through Watchtower's baked Google client).
package enum AddGoogleAccountCopy {
    package static let title = "Add Google Account"
    package static let close = "Close"
    package static let calendar = "Calendar"
    package static let gmail = "Gmail"
    package static let connect = "Connect"
    package static let connecting = "Connecting…"
    package static let cancel = "Cancel"
}

extension CompanyConnectionsPresentation {
    /// The Connect… menu's last entries (company screens spec §2.1).
    package static let connectMenuCompanyActions: [CompaniesZoneState.Action] = [.setUpForCompany, .connectWithCode]

    /// Whether the Add Google Account sheet (Watchtower's baked client) may
    /// ask for Gmail. Go's `googleOnSharedClient`: only the public,
    /// flavorless build bakes the shared app, which asks for Calendar only
    /// (D11); a flavored build bakes its company's app (or a developer's).
    package static func sharedGoogleOffersGmail(buildFlavor: String) -> Bool {
        !buildFlavor.isEmpty
    }

    /// Under the shared sheet's switched-off Gmail.
    package static func sharedGoogleGmailNote(locks: Set<LockKey>) -> String {
        let head = "Watchtower's shared Google app connects Calendar only. "
        if locks.contains(.ownGoogleProject) {
            return head + "Gmail needs your company's Google project: ask your admin for the link."
        }
        return head + "Gmail needs a Google project: your company's (ask your admin for the link) or your own. "
            + "Connect it in Connections → Google."
    }

    /// The Email sheet's Gmail card button.
    package static let connectGmail = "Connect Gmail"

    /// The Email sheet's Gmail card line.
    package static func gmailCardLine(offersGmail: Bool, locks: Set<LockKey>) -> String {
        if offersGmail { return "Google's OAuth flow — supports multiple Google accounts." }
        if locks.contains(.ownGoogleProject) {
            return "Gmail needs your company's Google project. Connect opens Connections → Google."
        }
        return "Gmail needs a Google project: your company's or your own. Connect opens Connections → Google."
    }

    /// **Connect Gmail**: the sheet when the build's client asks for Gmail;
    /// else a stored company's Google app (its row in the Google detail), the
    /// own project page, or — own projects locked — the detail's company code.
    /// `companiesKnown` is false while the company files are unread or
    /// failed to read: the detail then, never the own project page over a
    /// company Google app nobody could see.
    package static func gmailRoute(
        offersGmail: Bool,
        companies: [CompanyRef],
        companiesKnown: Bool,
        locks: Set<LockKey>
    ) -> GmailRoute {
        if offersGmail { return .sharedSheet }
        guard companiesKnown else { return .googleDetail }
        let companyGoogle = companies.contains { !$0.personal && $0.vendors[.google] != nil }
        if companyGoogle || locks.contains(.ownGoogleProject) { return .googleDetail }
        return .ownProjectPage
    }
}
