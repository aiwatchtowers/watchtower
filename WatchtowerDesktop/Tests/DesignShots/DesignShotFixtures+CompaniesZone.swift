import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

private typealias Pres = CompanyConnectionsPresentation

/// The production Companies zone and grouped account lists (#1887 Task 25a)
/// over sample data (`Acme`, `example.com`, made-up ids), for the
/// `company-overview-*`, `company-slack-workspaces`, `company-linear-detail`
/// and `company-outlook-detail` shots.
@MainActor
enum CompaniesZoneScenes {
    private static let allVendors: [CompanyVendor: String] = [
        .slack: Pres.slackAppDetail(appID: "A0ACME"), .google: "example.com", .atlassian: "https://acme.atlassian.net",
        .linear: "", .microsoft: "0000-acme"
    ]
    static let acme = CompanyRef(slug: "acme", name: "Acme", vendors: allVendors)
    private static let acmeManaged = CompanyRef(slug: "acme", name: "Acme", forced: true, vendors: allVendors)

    private static func ref(
        _ vendor: CompanyVendor,
        _ id: Int,
        _ label: String,
        slug: String = "acme",
        status: String = "ok",
        error: String = ""
    ) -> AccountRef {
        AccountRef(vendor: vendor, accountID: id, label: label, companySlug: slug, status: status, error: error)
    }

    /// Slack, Jira and Outlook connected: "3 of 5", Gmail and Linear missing.
    private static let threeOfFive = [ref(.slack, 1, "acme"), ref(.atlassian, 2, "acme.atlassian.net"),
                                      ref(.microsoft, 3, "alice@example.com")]
    /// Slack, Google, Outlook fine; Atlassian replaced; Linear missing.
    private static let replaced = [ref(.slack, 1, "acme"), ref(.google, 4, "alice@example.com"),
                                   ref(.microsoft, 3, "alice@example.com"),
                                   ref(.atlassian, 2, "acme.atlassian.net", status: "error", error: "company_changed_app")]

    // MARK: Overview

    static func overview(_ frame: CompanySetupShotFixtures.Overview) -> some View {
        let zone: CompaniesZoneState = switch frame {
        case .companies, .codePaste:
            Pres.zone(companies: [acme], errors: [], draft: nil, accounts: threeOfFive, portBusy: false, loading: false)
        case .mdm:
            Pres.zone(companies: [acmeManaged], errors: [], draft: nil, accounts: [], portBusy: false, loading: false)
        case .relogin:
            Pres.zone(companies: [acme], errors: [], draft: nil, accounts: replaced, portBusy: false, loading: false)
        case .empty:
            Pres.zone(companies: [], errors: [], draft: nil, accounts: [], portBusy: false, loading: false)
        case .loading:
            Pres.zone(companies: [], errors: [], draft: nil, accounts: [], portBusy: false, loading: true)
        case .readFailed:
            Pres.zone(companies: [], errors: [CompanyFileError(file: "acme.json", error: "bad json")], draft: nil,
                      accounts: [], portBusy: false, loading: false)
        case .portBusy:
            Pres.zone(companies: [acme], errors: [], draft: nil, accounts: threeOfFive, portBusy: true, loading: false)
        case .setupInProgress:
            Pres.zone(companies: [acme], errors: [], draft: .inProgress(company: "Acme", step: "Atlassian", index: 3, count: 8),
                      accounts: threeOfFive, portBusy: false, loading: false)
        }
        let model: CompaniesZoneModel = frame == .codePaste
            ? .preview(code: "acme-onboarding-2026", codeError: Pres.codeInvalid)
            : CompaniesZoneModel { nil }
        return ConnectionsOverviewContent(
            summaries: summaries(frame),
            companies: CompaniesZone(state: zone, model: model, actions: CompaniesZoneActions())
        ) { _ in }
        .controlSize(.small)
        .detailBackground()
    }

    private static func summaries(_ frame: CompanySetupShotFixtures.Overview) -> [ConnectionSummary] {
        let jira = frame == .relogin
            ? ConnectionAccountState(name: "acme.atlassian.net", isOK: false, status: "error",
                                     error: Pres.reloginChanged("Acme"))
            : ConnectionAccountState(name: "acme.atlassian.net", isOK: true, status: "ok", error: "")
        return [
            ConnectionSummary(service: .slack, accounts: [
                ConnectionAccountState(name: "acme", isOK: true, status: "ok", error: "")
            ], blocked: false),
            ConnectionSummary(service: .google, accounts: [], blocked: false),
            ConnectionSummary(service: .jira, accounts: [jira], blocked: false)
        ]
    }

    // MARK: Grouped account lists

    static var panes: [(String, AnyView)] {
        [
            ("slack-workspaces", AnyView(pane(.slack, accounts: [
                ref(.slack, 1, "acme"),
                ref(.slack, 2, "acme-labs", slug: "", status: "error", error: "unknown_client")
            ]))),
            ("linear-detail", AnyView(pane(.linear, accounts: [ref(.linear, 1, "Side project", slug: "")]))),
            ("outlook-detail", AnyView(pane(.microsoft, accounts: [
                ref(.microsoft, 1, "alice@example.com"), ref(.microsoft, 2, "alice@example.org", slug: "")
            ])))
        ]
    }

    private static func pane(_ vendor: CompanyVendor, accounts: [AccountRef]) -> some View {
        let groups = Pres.groups(vendor: vendor, accounts: accounts, companies: [acme]) { _ in false }
        return VStack(alignment: .leading, spacing: Spacing.large) {
            CompanyAccountGroups(groups: groups, connect: CompanyGroupConnect { _, _ in }, row: row)
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private static func row(_ account: AccountRef) -> some View {
        let status = Pres.rowStatus(account, purgeLease: nil, companies: [acme])
        return CompanyAccountRow(title: account.label, status: status, line: syncing) {
            if let action = status?.action {
                CompanyRowStatusButton(action: action) { _ in }
            }
        }
    }

    /// A syncing row's line in the shots (the details show their own).
    static let syncing = "Syncing · last sync 3 min ago"
}
