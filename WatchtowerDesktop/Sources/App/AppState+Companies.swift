import Foundation
import WatchtowerCore

/// The Companies zone and the accounts grouped by company (#1887 C3,
/// company screens spec §4): what the overview and the service details
/// read, and where their buttons go. Go writes every file and row; this
/// only reads and starts the company connect flow (`companyConnect`) or the
/// wizard page (`openCompanySetup`).
extension AppState {
    /// Every vendor's accounts as the presentation reads them; a service
    /// whose view model is not loaded yet adds none.
    var companyAccountRefs: [AccountRef] {
        var refs: [AccountRef] = []
        if let vm = slackAccountsViewModel {
            let shared = vm.sharedAppAccountIDs
            refs += vm.accounts.map { a in
                AccountRef(vendor: .slack, accountID: a.id, label: a.displayName, companySlug: a.companySlug,
                           status: a.status, error: a.error, sharedApp: shared.contains(a.id))
            }
        }
        refs += (googleAccountsViewModel?.accounts ?? []).map { a in
            AccountRef(vendor: .google, accountID: a.id, label: a.displayName, companySlug: a.companySlug,
                       status: a.status, error: a.error)
        }
        refs += (jiraAccountsViewModel?.accounts ?? []).map { a in
            AccountRef(vendor: .atlassian, accountID: a.id, label: URL(string: a.siteURL)?.host ?? a.displayName,
                       companySlug: a.companySlug, status: a.status, error: a.error, authKind: a.authKind)
        }
        refs += (linearAccountsViewModel?.accounts ?? []).map { a in
            AccountRef(vendor: .linear, accountID: Int(a.id), label: a.displayName, companySlug: a.companySlug,
                       status: a.status, error: a.error)
        }
        refs += (emailAccountsViewModel?.accounts ?? []).filter(\.isOutlook).map { a in
            AccountRef(vendor: .microsoft, accountID: a.id, label: a.displayName, companySlug: a.companySlug,
                       status: a.status, error: a.error)
        }
        return refs
    }

    /// The stored companies for the group captions; a company's Slack app is
    /// named from the setup record holding its client id.
    var companyRefs: [CompanyRef] {
        let zone = companiesZone
        return zone.companies.map { company in
            guard let clientID = zone.slackClientIDs[company.slug],
                  let record = slackAppSetup.records.first(where: { $0.clientID == clientID && !$0.appID.isEmpty })
            else { return company }
            var vendors = company.vendors
            vendors[.slack] = CompanyConnectionsPresentation.slackAppDetail(appID: record.appID)
            return CompanyRef(slug: company.slug, name: company.name, forced: company.forced,
                              personal: company.personal, vendors: vendors)
        }
    }

    /// The overview's zone over the live accounts and the listener's port.
    var companiesZoneState: CompaniesZoneState {
        companiesZone.zone(accounts: companyAccountRefs, portBusy: slackConnectListener?.state == .portBusy)
    }

    /// `vendor`'s §4.2 sections.
    func companyAccountGroups(_ vendor: CompanyVendor) -> [AccountGroup] {
        CompanyConnectionsPresentation.groups(
            vendor: vendor, accounts: companyAccountRefs.filter { $0.vendor == vendor }, companies: companyRefs
        ) { _ in false }
    }

    /// A row's §4.3 status (no purge lease here: Slack, Linear and Outlook
    /// have no token rows).
    func companyRowStatus(_ account: AccountRef) -> RowStatus? {
        CompanyConnectionsPresentation.rowStatus(account, purgeLease: nil, companies: companyRefs)
    }

    /// No card or row may start a company flow: none exists (no listener —
    /// under XCTest, or before the database opened), or one or another
    /// sign-in runs.
    var companyFlowBusy: Bool {
        companyConnect == nil || connectFlowRunning || slackAuthFlow.reconnecting
            || slackAccountsViewModel?.isConnecting == true
    }

    /// The card's spinner: the company whose chain waits on a vendor.
    var companyConnecting: (slug: String, vendor: CompanyVendor)? {
        guard let flow = companyConnect, let vendor = flow.currentVendor else { return nil }
        return (flow.slug, vendor)
    }

    /// The zone's buttons.
    var companiesZoneActions: CompaniesZoneActions {
        CompaniesZoneActions(
            setUpForCompany: { [weak self] in self?.openCompanySetup() },
            continueSetup: { [weak self] in self?.openCompanySetup() },
            tryAgain: { [weak self] in self?.reloadCompanies() },
            connectAll: { [weak self] slug in self?.runCompanyFlow { await $0.connectAll(slug: slug) } },
            connectRest: { [weak self] slug in self?.runCompanyFlow { await $0.connectRest(slug: slug) } },
            relogin: { [weak self] slug, vendors in self?.reloginCompany(slug: slug, vendors: vendors) },
            submitCode: { [weak self] in self?.submitCompanyCode() }
        )
    }

    /// Re-reads the zone (on the overview's appear, after a flow).
    func reloadCompanies() {
        Task { await companiesZone.reload() }
    }

    /// **Re-login** on a card or a row, and a Not connected row's
    /// **Connect**: the vendors' logins through the company's client, in a
    /// chain, no confirm (the owner's own press, §4.3).
    func reloginCompany(slug: String, vendors: [CompanyVendor]) {
        runCompanyFlow { await $0.relogin(slug: slug, vendors: vendors) }
    }

    /// A Not connected row's **Connect** in `vendor`'s detail.
    func companyGroupConnect(blocked: Bool) -> CompanyGroupConnect {
        CompanyGroupConnect(disabled: blocked || companyFlowBusy) { [weak self] slug, vendor in
            self?.reloginCompany(slug: slug, vendors: [vendor])
        }
    }

    /// A §4.3 status's own button on a row: **Re-login** after a Replace runs
    /// the vendor's login through the company's new app (a chain of one);
    /// **Paste a company code** opens the overview's code field, or `paste`
    /// where the detail has a field of its own (Slack's connect section).
    func companyRowAction(_ action: RowStatus.Action, account: AccountRef, paste: (() -> Void)? = nil) {
        switch action {
        case .relogin where !account.companySlug.isEmpty:
            reloginCompany(slug: account.companySlug, vendors: [account.vendor])
        case .connect where !account.companySlug.isEmpty:
            reloginCompany(slug: account.companySlug, vendors: [account.vendor])
        case .pasteCode, .relogin, .connect:
            if let paste { paste() } else { pasteCompanyCode() }
        case .pasteNewToken:
            break // Jira's API-token rows (Task 27)
        }
    }

    /// **Paste a company code** on a row: the overview's code field, opened.
    func pasteCompanyCode() {
        companiesZone.openCodeField()
        openConnections()
    }

    private func submitCompanyCode() {
        guard let flow = companyConnect else { return }
        Task { await companiesZone.submitCode { await flow.paste($0) } }
    }

    private func runCompanyFlow(_ start: @escaping @MainActor (CompanyConnectFlowModel) async -> Void) {
        guard let flow = companyConnect else { return }
        Task { await start(flow) }
    }
}
