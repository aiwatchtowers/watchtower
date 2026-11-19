import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

private typealias Pres = CompanyConnectionsPresentation

/// The production Google and Jira account sections (#1887 Task 25b) over
/// sample data (`Acme`, `example.com`, made-up ids), for the
/// `company-google-detail*` and `company-jira-detail*` shots; `-locked` and
/// `-tokenError` stay mocks until Tasks 26 and 27.
@MainActor
enum CompanyDetailScenes {
    private static let acme = CompaniesZoneScenes.acme
    /// The person's own Google project (a personal bundle, parent §4).
    private static let own = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.google: ""])

    private static func ref(
        _ vendor: CompanyVendor,
        _ id: Int,
        _ label: String,
        slug: String = "acme",
        status: String = "ok",
        error: String = "",
        authKind: String = "oauth",
        shared: Bool = false
    ) -> AccountRef {
        AccountRef(vendor: vendor, accountID: id, label: label, companySlug: slug, status: status, error: error,
                   authKind: authKind, sharedApp: shared)
    }

    private static let googleAccounts = [
        ref(.google, 1, "alice@example.com"),
        ref(.google, 2, "alice@example.net", slug: "me"),
        ref(.google, 3, "bob@example.org", slug: "", shared: true)
    ]
    private static let googleRelogin = [
        ref(.google, 1, "alice@example.com", status: "error", error: "company_changed_app"),
        ref(.google, 4, "dave@example.com", status: "error", error: "invalid_client"),
        ref(.google, 5, "erin@example.com", slug: "", status: "error", error: "unknown_client")
    ]
    /// The shared Atlassian row after the retirement: Go marks it unknown_client (D15 amended).
    private static let jiraAccounts = [
        ref(.atlassian, 1, "acme.atlassian.net"),
        ref(.atlassian, 2, "beta.atlassian.net", slug: "", authKind: "api_token"),
        ref(.atlassian, 3, "old.atlassian.net", slug: "", status: "error", error: "unknown_client", shared: true)
    ]

    static var panes: [(String, AnyView)] {
        [
            ("google-detail", pane(.google, accounts: googleAccounts)),
            ("google-detail-relogin", pane(.google, accounts: googleRelogin, banner: false)),
            ("google-detail-empty", pane(.google, accounts: [], companies: [])),
            ("google-detail-loading", pane(.google, accounts: [], loaded: false)),
            ("google-detail-readFailed", pane(.google, accounts: [], readError: "database is locked")),
            ("jira-detail", pane(.atlassian, accounts: jiraAccounts)),
            ("jira-detail-empty", pane(.atlassian, accounts: [], companies: [])),
            ("jira-detail-loading", pane(.atlassian, accounts: [], loaded: false)),
            ("jira-detail-readFailed", pane(.atlassian, accounts: [], readError: "database is locked"))
        ]
    }

    private static func pane(
        _ vendor: CompanyVendor,
        accounts: [AccountRef],
        companies: [CompanyRef]? = nil,
        loaded: Bool = true,
        readError: String? = nil,
        banner: Bool = true
    ) -> AnyView {
        let companies = companies ?? [acme, own]
        let groups = Pres.groups(vendor: vendor, accounts: accounts, companies: companies) { _ in false }
        // What this build offers: the API token waits for Task 27 (`AppState.unbuiltOffers`).
        let locks = AppState.unbuiltOffers
        let list = Pres.accountsList(vendor: vendor, loaded: loaded, readError: readError, accounts: accounts, groups: groups,
                                     locks: locks)
        return AnyView(VStack(alignment: .leading, spacing: Spacing.large) {
            CompanyAccountsSections(
                vendor: vendor,
                banner: banner ? Pres.banner(vendor, accounts: accounts, locks: locks) : nil,
                list: list,
                emptyActions: Pres.detailActions(vendor, companies: companies, empty: true, locks: locks),
                addActions: Pres.detailActions(vendor, companies: companies, empty: false, locks: locks),
                connect: CompanyGroupConnect { _, _ in },
                perform: { _ in },
                bannerAction: { _ in },
                tryAgain: {},
                row: { row($0, companies: companies) }
            )
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    private static func row(_ account: AccountRef, companies: [CompanyRef]) -> some View {
        let status = Pres.rowStatus(account, purgeLease: nil, companies: companies)
        let line = account.vendor == .google
            ? Pres.googleRowLine(account, calendar: true, gmail: !account.sharedApp || account.status == "ok")
            : Pres.jiraRowLine(account, title: account.label, enabled: true,
                               email: account.authKind == "api_token" ? "bob@example.com" : "alice@example.com")
        return CompanyAccountRow(title: account.label, tag: Pres.tag(account), status: status, line: line) {
            if let action = status?.action {
                CompanyRowStatusButton(action: action) { _ in }
            }
        }
    }
}
