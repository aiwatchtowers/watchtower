import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// The connect assistant spec's mockups (#2133,
/// `docs/superpowers/specs/2026-11-21-agent-connect-design.md` §7): the
/// panel in each state (`connect-assistant-<state>`) and the Connections
/// overview with **Connect with Claude** first (`connect-overview-agent`).
/// The panel is the real `ConnectAssistantPanel` over fixture chat lines;
/// the overview's agent buttons are a design-only variant of the cards and
/// the Companies zone. Sample data only (`acme`, `example.com`).
@MainActor
enum ConnectAssistantShotFixtures {
    private typealias Pres = ConnectAssistantPresentation
    private typealias Line = ConnectAssistantLine

    static var shots: [DesignShot] {
        panelShots + [
            DesignShot(name: "connect-overview-agent", size: NSSize(width: 1120, height: 720)) {
                AnyView(overview())
            }
        ]
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
        ("narrow", Pres(service: "Slack", harness: .codex, mode: .browser, browserAvailable: false, state: .empty), []),
        ("secret", slack(.secret(label: "Slack configuration token")), [
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

    private static func slack(_ state: ConnectAssistantState) -> Pres {
        Pres(service: "Slack", harness: .claude, mode: .browser, state: state)
    }

    private static var panelShots: [DesignShot] {
        scenes.map { name, presentation, lines in
            DesignShot(name: "connect-assistant-\(name)",
                       size: NSSize(width: ConnectAssistantPanel.width, height: 560)) {
                AnyView(ConnectAssistantPanel(presentation: presentation, lines: lines))
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
        HStack(spacing: 0) {
            ConnectOverviewAgentMock(summaries: summaries, harness: .claude)
                .detailBackground()
            Rectangle().fill(.separator).frame(width: Stroke.hairline)
            ConnectAssistantPanel(
                presentation: Pres(service: "Google", harness: .claude, mode: .browser, state: .empty), lines: [])
        }
        .controlSize(.small)
    }
}

/// Design only (spec §7): the Connections overview with **Connect with
/// <harness>** first on every unconnected source card, the attention
/// banner and the Companies zone, today's **Connect** beside it.
private struct ConnectOverviewAgentMock: View {
    let summaries: [ConnectionSummary]
    let harness: ConnectAssistantHarness

    private typealias Company = CompanyConnectionsPresentation

    private var withHarness: String { "Connect with \(harness.name)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack {
                    Text("Connections").font(.title2.weight(.bold))
                    Spacer()
                    Label("Connect…", systemImage: "plus")
                        .padding(.horizontal, Spacing.regular)
                        .padding(.vertical, Spacing.small)
                        .card()
                }
                ForEach(summaries.filter(\.needsAttention)) { summary in banner(summary) }
                companies
                group("Sources", ConnectionService.sources)
                group("Tools for AI", ConnectionService.aiTools)
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func banner(_ summary: ConnectionSummary) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text("\(summary.service.label) · \(summary.problemLine ?? "needs attention")").font(.callout)
            Spacer()
            agentButton("Reconnect with \(harness.name)")
            Button("Reconnect") {}.buttonStyle(.kitQuiet)
        }
        .padding(Spacing.medium)
        .card()
    }

    private var companies: some View {
        let zone = Company.zone(companies: [], errors: [], draft: nil, accounts: [], portBusy: false, loading: false)
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            HomeZoneTitle(title: Company.companiesTitle)
            if case .empty(let text) = zone.body {
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.regular) {
                agentButton(withHarness)
                ForEach(Array(zone.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title) {}.buttonStyle(.kitQuiet)
                }
            }
        }
    }

    private func group(_ title: String, _ services: [ConnectionService]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HomeZoneTitle(title: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: PaneWidth.gridCardMin), spacing: Spacing.medium,
                                         alignment: .top)],
                      alignment: .leading, spacing: Spacing.medium) {
                ForEach(summaries.filter { services.contains($0.service) }) { card($0) }
            }
        }
    }

    private func card(_ summary: ConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: summary.service.icon).foregroundStyle(.secondary)
                Text(summary.service.label).font(.headline)
                Spacer()
                ConnectionStatusMark(summary: summary)
            }
            Text(summary.countLine).font(.caption).foregroundStyle(.secondary)
            Text(summary.statusLine)
                .font(.caption)
                .foregroundStyle(summary.needsAttention ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary))
                .lineLimit(2)
            if summary.accountCount == 0 && !summary.blocked {
                HStack(spacing: Spacing.regular) {
                    agentButton(withHarness)
                    Button("Connect") {}.buttonStyle(.kitQuiet)
                }
                .padding(.top, Spacing.small)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func agentButton(_ title: String) -> some View {
        Button {} label: { Label(title, systemImage: "sparkles") }
            .buttonStyle(.kitSecondary)
    }
}
