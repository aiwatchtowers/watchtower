import Foundation
import WatchtowerCore

/// The Google and Jira details over the company presentation (#1887 Task
/// 25b, company screens spec §4.2, §5.3, §6.4, §7): their list state, the
/// banner, the add section's buttons and where those go.
extension AppState {
    /// The policy locks in force (§5.4, §6.5).
    var companyLocks: Set<LockKey> {
        let policy = managedPolicy.policy
        return CompanyConnectionsPresentation.locks(
            ownGoogleProjectAllowed: policy.ownGoogleProjectAllowed,
            atlassianAPITokenAllowed: policy.atlassianAPITokenAllowed)
    }

    /// Ways to connect this build does not offer yet, left out as their lock
    /// would leave them out: the API token waits for Task 27's sheet, which
    /// empties this set.
    static let unbuiltOffers: Set<LockKey> = [.atlassianAPIToken]

    /// What the banners, empty states and add sections leave out.
    var companyOfferLocks: Set<LockKey> { companyLocks.union(Self.unbuiltOffers) }

    /// §7's banner over `vendor`'s detail.
    func companyBanner(_ vendor: CompanyVendor) -> CompanyBanner? {
        CompanyConnectionsPresentation.banner(
            vendor, accounts: companyAccountRefs.filter { $0.vendor == vendor }, locks: companyOfferLocks)
    }

    /// `vendor`'s account list: loading, read failed, empty or the groups.
    func companyAccountsList(_ vendor: CompanyVendor) -> AccountsListState {
        let read: (loaded: Bool, error: String?) = switch vendor {
        case .google: (googleAccountsViewModel?.hasRead ?? false, googleAccountsViewModel?.readError)
        case .atlassian: (jiraAccountsViewModel?.hasRead ?? false, jiraAccountsViewModel?.readError)
        case .slack, .linear, .microsoft: (true, nil)
        }
        return CompanyConnectionsPresentation.accountsList(
            vendor: vendor, loaded: read.loaded, readError: read.error,
            accounts: companyAccountRefs.filter { $0.vendor == vendor }, groups: companyAccountGroups(vendor),
            locks: companyOfferLocks)
    }

    /// The empty state's or the add section's buttons.
    func companyDetailActions(_ vendor: CompanyVendor, empty: Bool) -> [DetailAction] {
        CompanyConnectionsPresentation.detailActions(vendor, companies: companyRefs, empty: empty, locks: companyOfferLocks)
    }

    /// A Google or Jira detail's buttons wait while its own sign-in, the own
    /// Google project's or a company chain runs: two browser sign-ins never
    /// start at once.
    func companyDetailBusy(_ vendor: CompanyVendor) -> Bool {
        let own = switch vendor {
        case .google: (googleAccountsViewModel?.isConnecting ?? true) || ownGoogleProject.isRunning
        case .atlassian: jiraAccountsViewModel?.isConnecting ?? true
        case .slack, .linear, .microsoft: false
        }
        return own || companyConnect?.isRunning == true
    }

    /// The own Google project page's model (#1887 C4): waits for the other
    /// Google sign-ins, and a connect re-reads the accounts and re-wires the
    /// daemon.
    func makeOwnGoogleProject(
        makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?
    ) -> OwnGoogleProjectModel {
        let model = OwnGoogleProjectModel(makeStreamer: makeStreamer)
        model.externalBusy = { [weak self] in
            // The detail's own busy rule; the model checks its own run itself.
            self?.companyDetailBusy(.google) ?? true
        }
        model.onConnected = { [weak self] in
            guard let self else { return }
            googleAccountsViewModel?.accountAddedElsewhere(daemonPolicy: accountDaemonPolicy)
            reloadCompanies() // the personal bundle Go stored names the group
        }
        return model
    }

    /// A Google account on the person's own project (Go's `own_project`,
    /// or tied to a personal bundle).
    func isOwnGoogleProject(_ ref: AccountRef) -> Bool {
        let own = googleAccountsViewModel?.sharedFlags.ownProjectIDs ?? []
        return CompanyConnectionsPresentation.isOwnGoogleProject(ref, companies: companyRefs) { own.contains($0.accountID) }
    }

    /// A row the policy stops (§5.4): an own-project Google account while
    /// own projects are not allowed. Go stops its sync and keeps its data.
    func companyRowStoppedByPolicy(_ ref: AccountRef) -> Bool {
        companyLocks.contains(.ownGoogleProject) && isOwnGoogleProject(ref)
    }

    /// A detail button that needs no view state of its own (the detail opens
    /// its own sheets): a company code, a company's app, Calendar, the wizard.
    func performCompanyDetailAction(_ kind: DetailAction.Kind, vendor: CompanyVendor) {
        switch kind {
        case .pasteCode:
            pasteCompanyCode()
        case .connectCompany(let slug):
            reloginCompany(slug: slug, vendors: [vendor])
        case .connectCalendar:
            // Calendar only: the shared Google app requests no Gmail (D11).
            googleAccountsViewModel?.addAccount(calendar: true, gmail: false, clientID: "", clientSecret: "",
                                                daemonPolicy: accountDaemonPolicy)
        default:
            break // the detail's own sheet or page
        }
    }

    /// A banner button (§7); **Use my own Google project** is the detail's.
    func performCompanyBannerAction(_ action: CompanyBanner.Action) {
        switch action {
        case .pasteCode: pasteCompanyCode()
        case .setUpForCompany: openCompanySetup()
        default: break // the detail's own sheet or page
        }
    }

    /// The overview card's line for a banner, never a problem (§7).
    func companyBannerCardLine(_ service: ConnectionService) -> String? {
        switch service {
        case .google: companyBanner(.google)?.cardLine
        case .jira: companyBanner(.atlassian)?.cardLine
        default: nil
        }
    }
}
