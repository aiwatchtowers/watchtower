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

    /// §7's banner over `vendor`'s detail; its actions without the ones this
    /// build cannot run yet (`shippable`).
    func companyBanner(_ vendor: CompanyVendor) -> CompanyBanner? {
        Self.shippable(CompanyConnectionsPresentation.banner(
            vendor, accounts: companyAccountRefs.filter { $0.vendor == vendor }, locks: companyLocks))
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
            accounts: companyAccountRefs.filter { $0.vendor == vendor }, groups: companyAccountGroups(vendor))
    }

    /// The empty state's or the add section's buttons.
    func companyDetailActions(_ vendor: CompanyVendor, empty: Bool) -> [DetailAction] {
        Self.shippable(CompanyConnectionsPresentation.detailActions(
            vendor, companies: companyRefs, empty: empty, locks: companyLocks))
    }

    /// Jira's **Connect with an API token** opens Task 27's sheet; until it
    /// lands the button is left out rather than shown dead.
    static let atlassianTokenSheetShips = false

    static func shippable(_ actions: [DetailAction]) -> [DetailAction] {
        actions.filter { $0.kind != .connectWithToken || atlassianTokenSheetShips }
    }

    static func shippable(_ banner: CompanyBanner?) -> CompanyBanner? {
        atlassianTokenSheetShips ? banner : banner?.dropping(.connectWithToken)
    }

    /// A detail button that needs no view state of its own (the detail opens
    /// its own sheets): a company code, a company's app, the wizard.
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
        case .useOwnGoogle, .connectWithToken:
            break // the detail's own sheet or page
        }
    }

    /// A banner button (§7); **Use my own Google project** is the detail's.
    func performCompanyBannerAction(_ action: CompanyBanner.Action) {
        switch action {
        case .pasteCode: pasteCompanyCode()
        case .setUpForCompany: openCompanySetup()
        case .useOwnGoogle, .connectWithToken: break
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
