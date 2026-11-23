import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The connect assistant spec's shots (#2133,
/// `docs/superpowers/specs/2026-11-21-agent-connect-design.md` §7): the
/// panel in each state (`connect-assistant-<state>`) and the Connections
/// overview with **Connect with Claude** first (`connect-overview-agent`).
/// The built views: the panel over fixture chat lines (a live run hosts the
/// embedded chat in their place), and the overview, Companies zone and
/// banner with their agent buttons. Sample data only (`acme`, `example.com`).
@MainActor
enum ConnectAssistantShotFixtures {
    private typealias Pres = ConnectAssistantPresentation
    private typealias Line = ConnectAssistantLine

    static var shots: [DesignShot] {
        panelShots + [
            DesignShot(name: "connect-overview-agent", size: NSSize(width: 1120, height: 720)) {
                AnyView(overview())
            }
        ] + ConnectAssistantScreenFixtures.shots
    }

    /// The picker's harnesses as the fixture catalog offers them, every
    /// provider ready and allowed.
    static var harnesses: [ConnectHarness] {
        let providers = ProviderCatalogFixture.providers()
        return ConnectHarnessCatalog.offered(providers: providers, allowed: nil, ready: Set(providers.map(\.id)),
                                             base: "claude").harnesses
    }

    private static let created = Line(.assistant, "I opened api.slack.com and created the app from Watchtower's manifest.")

    private static let scenes: [(String, Pres, [Line])] = [
        ("empty", slack(.empty), []),
        ("loading", slack(.waiting(step: "press Allow in Slack")), [
            Line(.assistant, "I'll connect Slack with you. Start?"), Line(.customer, "Start"), created,
            Line(.assistant, "Slack shows its permission page in Chrome. Sign in if it asks, then press Allow — "
                + "I'll wait here.")
        ]),
        ("error", slack(.failed(.quota)), [
            Line(.assistant, "I'll connect Slack with you. Start?"), Line(.customer, "Start"), created
        ]),
        ("busy", slack(.busy), []),
        ("narrow", Pres(service: "Slack", harness: .fixture("codex"), mode: .browser, browserAvailable: false,
                        state: .empty), []),
        // #1144: Start's probe found no browser — the guide before the first turn.
        ("browser-missing", Pres(service: "Slack", harness: .fixture("claude"), mode: .words, browserAvailable: false,
                                 state: .browserMissing, browserCheck: .stillMissing), []),
        // #1144: the browser lost mid-run — the run goes on in words beside the guide.
        ("browser-lost", browserLost, [
            created,
            Line(.assistant, "Chrome stopped answering me. Open api.slack.com/apps and click Create New App — "
                + "tell me when you see the dialog.")
        ]),
        ("secret", slackSecret, [
            created,
            Line(.assistant, "Copy the configuration token shown on the page into the field below. "
                + "It goes to Watchtower, not to me.")
        ]),
        ("confirm", slack(.confirm(.slackPKCE)), [
            created,
            Line(.assistant, "The app is ready. Watchtower signs in to it with PKCE, which Slack can't turn off again. "
                + "Press Confirm below if that's fine.")
        ]),
        ("done", slack(.done(accounts: 2, noun: .workspace)), [
            Line(.assistant, "You pressed Allow: the acme workspace is connected."),
            Line(.customer, "Add acme-labs too"),
            Line(.assistant, "Done — acme-labs is connected as well.")
        ])
    ]

    private static let browserLost = Pres(service: "Slack", harness: .fixture("claude"), mode: .words,
                                          browserAvailable: false, state: .listening, browserCheck: .notChecked)

    private static let slackSecret = Pres(service: "Slack", harness: .fixture("claude"), mode: .browser,
                                          state: .secret(label: "Slack configuration token"),
                                          secretKind: "slack_config_token")

    private static func slack(_ state: ConnectAssistantState) -> Pres {
        Pres(service: "Slack", harness: .fixture("claude"), mode: .browser, state: state)
    }

    private static var panelShots: [DesignShot] {
        scenes.map { name, presentation, lines in
            DesignShot(name: "connect-assistant-\(name)",
                       size: NSSize(width: ConnectAssistantPanel.width, height: 560)) {
                AnyView(ConnectAssistantPanel(presentation: presentation, harnesses: harnesses, lines: lines))
            }
        }
    }

    // MARK: Overview

    private static let summaries: [ConnectionSummary] = [
        ConnectionSummary(service: .slack, accounts: [
            ConnectionAccountState(name: "acme", isOK: true, status: "ok", error: "")
        ], blocked: false),
        ConnectionSummary(service: .google, accounts: [], blocked: false),
        ConnectionSummary(service: .email, accounts: [], blocked: false),
        ConnectionSummary(service: .calendar, accounts: [
            ConnectionAccountState(name: "alice@example.com", isOK: true, status: "ok", error: "")
        ], blocked: false),
        ConnectionSummary(service: .jira, accounts: [
            ConnectionAccountState(name: "acme.atlassian.net", isOK: false, status: "error", error: "token expired")
        ], blocked: false),
        ConnectionSummary(service: .linear, accounts: [], blocked: false),
        ConnectionSummary(service: .quickConnections, accounts: [], blocked: false)
    ]

    /// The overview with the assistant open on Google, in the panel slot on the right.
    private static func overview() -> some View {
        let claude = ConnectHarness.fixture("claude")
        let agent = ConnectAgentEntry(harness: { _ in claude }, open: { _ in })
        let zone = CompanyConnectionsPresentation.zone(
            companies: [], errors: [], draft: nil, accounts: [], portBusy: false, loading: false)
        let companies = CompaniesZone(state: zone, model: CompaniesZoneModel { nil }, actions: CompaniesZoneActions(),
                                      agent: (claude, {}))
        let ignore: (ConnectionService) -> Void = { _ in }
        return HStack(spacing: 0) {
            ConnectionsOverviewContent(summaries: summaries, companies: companies, onCompanyAction: { _ in },
                                       agent: agent, onOpen: ignore)
            .detailBackground()
            Rectangle().fill(Stroke.hairlineColor).frame(width: Stroke.hairline)
            ConnectAssistantPanel(
                presentation: Pres(service: "Google", harness: claude, mode: .browser, state: .empty),
                harnesses: harnesses)
        }
        .controlSize(.small)
    }
}
