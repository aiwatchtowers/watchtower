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

    /// §7's banner over `vendor`'s detail.
    func companyBanner(_ vendor: CompanyVendor) -> CompanyBanner? {
        CompanyConnectionsPresentation.banner(
            vendor, accounts: companyAccountRefs.filter { $0.vendor == vendor }, locks: companyLocks)
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
            locks: companyLocks)
    }

    /// The empty state's or the add section's buttons.
    func companyDetailActions(_ vendor: CompanyVendor, empty: Bool) -> [DetailAction] {
        CompanyConnectionsPresentation.detailActions(vendor, companies: companyRefs, empty: empty, locks: companyLocks)
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
    /// daemon; a Cancel only re-reads them.
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
        model.onCancelled = { [weak self] in
            // A sign-in killed while Go saved leaves what it saved: show it,
            // refresh only (spec "Cancel lands while the CLI is saving").
            guard let self else { return }
            googleAccountsViewModel?.refresh()
            reloadCompanies()
        }
        return model
    }

    /// A Google account on the person's own project (Go's `own_project`,
    /// or tied to a personal bundle).
    func isOwnGoogleProject(_ ref: AccountRef) -> Bool {
        let own = googleAccountsViewModel?.sharedFlags.ownProjectIDs ?? []
        return CompanyConnectionsPresentation.isOwnGoogleProject(ref, companies: companyRefs) { own.contains($0.accountID) }
    }

    /// A row the policy stops: an own-project Google account while own
    /// projects are not allowed (§5.4), an API-token Jira site while tokens
    /// are not (§6.5). Go stops its sync and keeps its data.
    func companyRowStoppedByPolicy(_ ref: AccountRef) -> Bool {
        (companyLocks.contains(.ownGoogleProject) && isOwnGoogleProject(ref))
            || (companyLocks.contains(.atlassianAPIToken) && ref.isAPIToken)
    }

    /// A detail button that needs no view state of its own (the detail opens
    /// its own sheets and pages): a company code, a company's app, Calendar,
    /// the API-token sheet (its model lives here; the Jira detail shows it).
    func performCompanyDetailAction(_ kind: DetailAction.Kind, vendor: CompanyVendor) {
        switch kind {
        case .pasteCode:
            pasteCompanyCode()
        case .connectCompany(let slug):
            reloginCompany(slug: slug, vendors: [vendor])
        case .connectWithToken:
            openAtlassianToken { $0.openAdd() }
        case .connectCalendar:
            // Calendar only: the shared Google app requests no Gmail (D11).
            googleAccountsViewModel?.addAccount(calendar: true, gmail: false, clientID: "", clientSecret: "",
                                                daemonPolicy: accountDaemonPolicy)
        case .setUpForCompany:
            openCompanySetup()
        default:
            break // the detail's own sheet or page
        }
    }

    /// A banner button (§7); **Use my own Google project** is the detail's.
    /// **Connect with an API token** opens the token sheet the Jira detail shows.
    func performCompanyBannerAction(_ action: CompanyBanner.Action) {
        switch action {
        case .pasteCode: pasteCompanyCode()
        case .setUpForCompany: openCompanySetup()
        case .connectWithToken: openAtlassianToken { $0.openAdd() }
        default: break // the detail's own sheet or page
        }
    }

    /// Opens the API-token sheet (§6.2) the Jira detail shows; a run that
    /// connects reloads the Jira sites and re-wires the daemon, as a finished
    /// `jira add` / `jira login` does.
    func openAtlassianToken(_ open: (AtlassianTokenFormModel) -> Void) {
        atlassianToken.onConnected = { [weak self] in
            guard let self else { return }
            jiraAccountsViewModel?.tokenWroteAccount(daemonPolicy: accountDaemonPolicy)
        }
        open(atlassianToken)
    }

    /// The overview card's line for a banner, never a problem (§7).
    func companyBannerCardLine(_ service: ConnectionService) -> String? {
        switch service {
        case .google: companyBanner(.google)?.cardLine
        case .jira: companyBanner(.atlassian)?.cardLine
        default: nil
        }
    }

    // MARK: Gmail (D11)

    /// Whether the Add Google Account sheet may ask for Gmail: the build's
    /// baked Google client is not Watchtower's shared app.
    var sharedGoogleOffersGmail: Bool {
        CompanyConnectionsPresentation.sharedGoogleOffersGmail(buildFlavor: CompanyBridgeLaunch.bundleFlavor)
    }

    /// Email → Add Account → **Connect Gmail** where the sheet cannot ask for
    /// Gmail: the Google detail, opened on the own Google project page unless
    /// a company's Google app, the policy (Google blocked, own projects
    /// locked) or company files that could not be read make the detail the
    /// way. The companies are read afresh first: the zone's last read may be
    /// from before a link or the CLI stored a company, or never have run.
    /// The caller closes its sheet first.
    func connectGmail() async {
        // A read superseded by a newer one leaves the older snapshot: unknown, so the detail.
        let landed = await companiesZone.reload()
        let route = CompanyConnectionsPresentation.gmailRoute(
            companies: companyRefs, companiesKnown: landed && companiesZone.readEveryCompany,
            googleAllowed: managedPolicy.policy.sourceAllowed("google"), locks: companyLocks)
        if route == .ownProjectPage { ownGoogleProject.open() }
        openConnections(.google)
    }
}
