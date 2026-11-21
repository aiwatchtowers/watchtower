import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// The connect assistant spec's entry points beyond the overview (#2133,
/// §7): a service detail's **Add an account** (`connect-detail-add-account`)
/// and the onboarding Connect step (`connect-onboarding-step`), each with
/// **Connect with Claude** first and today's controls beside it. Design-only
/// copies of `GoogleConnectionDetail` and `OnboardingConnectStepView`; sample
/// data only (`acme`, `example.com`).
@MainActor
enum ConnectAssistantScreenFixtures {
    static var shots: [DesignShot] {
        [
            DesignShot(name: "connect-detail-add-account", size: NSSize(width: 860, height: 0)) {
                AnyView(GoogleDetailAgentMock(harness: .claude))
            },
            DesignShot(name: "connect-onboarding-step", size: NSSize(width: 860, height: 0)) {
                AnyView(OnboardingConnectAgentMock(harness: .claude))
            }
        ]
    }
}

/// The sparkles button that opens the assistant (spec §7): secondary, never
/// the screen's prominent one.
private struct AgentConnectButton: View {
    let title: String

    var body: some View {
        Button {} label: { Label(title, systemImage: "sparkles") }
            .buttonStyle(.kitSecondary)
    }
}

/// Design only: the Google detail pane with two accounts and **Add an
/// account** offering the assistant beside today's Google buttons.
private struct GoogleDetailAgentMock: View {
    let harness: ConnectAssistantHarness

    private typealias Pres = CompanyConnectionsPresentation

    private static let own = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.google: ""])
    private static let companies = [CompaniesZoneScenes.acme, own]
    private static let accounts = [
        AccountRef(vendor: .google, accountID: 1, label: "alice@example.com", companySlug: "acme", status: "ok", error: ""),
        AccountRef(vendor: .google, accountID: 2, label: "alice@example.net", companySlug: "me", status: "ok", error: "")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            CompanyAccountGroups(
                groups: Pres.groups(vendor: .google, accounts: Self.accounts, companies: Self.companies) { _ in false },
                connect: CompanyGroupConnect { _, _ in }
            ) { ref in row(ref) }
            SettingsSection(title: Pres.addAccountTitle) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.regular) { addButtons }
                    VStack(alignment: .leading, spacing: Spacing.regular) { addButtons }
                }
            }
            SettingsSection(title: "Google Calendar") {
                Toggle("Enable calendar sync", isOn: .constant(true))
                Picker("Sync days ahead", selection: .constant(7)) {
                    Text("7 days").tag(7)
                }
                .fixedSize()
            }
            SettingsSection(title: "Gmail") {
                Toggle("Enable Gmail sync", isOn: .constant(true))
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    @ViewBuilder private var addButtons: some View {
        AgentConnectButton(title: "Connect with \(harness.name)")
        ForEach(Pres.detailActions(.google, companies: Self.companies, empty: false)) { action in
            if action.emphasis == .quiet {
                Button(action.title) {}.buttonStyle(.kitQuiet)
            } else {
                Button(action.title) {}.buttonStyle(.kitSecondary)
            }
        }
    }

    private func row(_ ref: AccountRef) -> some View {
        CompanyAccountRow(
            title: ref.label,
            tag: Pres.tag(ref),
            line: Pres.googleRowLine(ref, calendar: true, gmail: true)
        ) {
            Button("Rename…") {}.buttonStyle(.kitQuiet)
            Button("Remove") {}.buttonStyle(.kitQuiet).foregroundStyle(Tone.error)
        }
    }
}

/// Design only: onboarding step 2 with **Connect with Claude** first on every
/// source row and today's **Connect** second; **Continue** stays the one
/// prominent button.
private struct OnboardingConnectAgentMock: View {
    let harness: ConnectAssistantHarness

    private static let sources: [(letter: String, title: String, subtitle: String)] = [
        ("S", "Slack", "Messages, mentions, threads · for work communication"),
        ("G", "Google", "Calendar and Gmail · for meetings and mail"),
        ("J", "Jira", "Issues and boards · for tasks"),
        ("L", "Linear", "Issues, cycles and projects · for tasks")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            OnboardingStepIndicator(steps: [.purpose, .connect, .aiConsent], current: .connect)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Connect your sources").font(.headline)
                Text("Only what your goals need. Skip any of them and connect later in the Connections tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: Spacing.small) {
                ForEach(Self.sources, id: \.title) { row($0) }
            }
            Label("Everything stays on your Mac. \(harness.name) walks you through each sign-in; "
                  + "Connect opens the same sheet as in Settings.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("You can continue without any")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {} label: { Text("Continue").fontWeight(.semibold).frame(minWidth: 120) }
                    .onboardingPrimaryButton()
            }
            .padding(.top, Spacing.regular)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Surface.window)
    }

    private func row(_ source: (letter: String, title: String, subtitle: String)) -> some View {
        HStack(spacing: Spacing.medium) {
            Text(source.letter)
                .fontWeight(.bold)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Fill.hover))
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(source.title).fontWeight(.semibold)
                Text(source.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            AgentConnectButton(title: "Connect with \(harness.name)")
            Button("Connect") {}.buttonStyle(.kitQuiet)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .card()
    }
}
