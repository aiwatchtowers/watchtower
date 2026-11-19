import Foundation

/// Where Email → Add Account → **Connect Gmail** goes on the public build
/// (#1887 D11: the shared Google app asks for Calendar only; a flavored
/// build keeps the Add Google Account sheet).
package enum GmailRoute: Equatable, Sendable {
    /// The own Google project page in the Google detail (§5.2).
    case ownProjectPage
    /// The Google detail: a stored company's Google row (§5.3), or the empty
    /// state's company code while own projects are locked (§5.4), or its
    /// blocked notice while the organization blocks Google.
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
    /// ask for Gmail. Go (`googleOnSharedClient`) refuses Gmail on the
    /// public, flavorless build's baked shared app (D11); a flavored build
    /// bakes its company's app (or a developer's). Conservative: a
    /// flavorless build without a baked client (a local source build) also
    /// keeps Gmail off here, though Go would accept it with an env client.
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

    /// The onboarding Google card's subtitle: mail only where the sheet
    /// can ask for it.
    package static func onboardingGoogleSubtitle(offersGmail: Bool) -> String {
        offersGmail ? "Mail and calendar · for work communication and meetings"
            : "Calendar · for meetings; Gmail connects later in Connections"
    }

    /// **Connect Gmail** on the public build: a stored company's Google app
    /// (its row in the Google detail), the own project page, or — own
    /// projects locked — the detail's company code. `companiesKnown` is
    /// false while the company files are unread or failed to read: the
    /// detail then, never the own project page over a company Google app
    /// nobody could see. A blocked Google source is the detail too, whose
    /// buttons say so (the page itself checks no policy).
    package static func gmailRoute(
        companies: [CompanyRef],
        companiesKnown: Bool,
        googleAllowed: Bool,
        locks: Set<LockKey>
    ) -> GmailRoute {
        guard companiesKnown, googleAllowed, !locks.contains(.ownGoogleProject) else { return .googleDetail }
        let companyGoogle = companies.contains { !$0.personal && $0.vendors[.google] != nil }
        return companyGoogle ? .googleDetail : .ownProjectPage
    }
}
