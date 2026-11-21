import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The connect assistant spec's entry points beyond the overview (#2133,
/// §7): a service detail's **Add an account** (`connect-detail-add-account`)
/// and the onboarding Connect step (`connect-onboarding-step`), each with
/// **Connect with Claude** first and today's controls beside it. Built from
/// the screens' own parts (`CompanyAccountsSections`,
/// `OnboardingConnectSourceRow`); sample data only (`acme`, `example.com`).
@MainActor
enum ConnectAssistantScreenFixtures {
    static var shots: [DesignShot] {
        [
            DesignShot(name: "connect-detail-add-account", size: NSSize(width: 860, height: 0)) {
                AnyView(GoogleDetailAgentScene(harness: .fixture("claude")))
            },
            DesignShot(name: "connect-onboarding-step", size: NSSize(width: 860, height: 0)) {
                AnyView(OnboardingConnectAgentScene(harness: .fixture("claude")))
            },
            // The step beside the 380 pt panel in the 800 pt minimum window: the pair stacks.
            DesignShot(name: "connect-onboarding-step-narrow", size: NSSize(width: 420, height: 0)) {
                AnyView(OnboardingConnectAgentScene(harness: .fixture("claude")))
            }
        ]
    }
}

/// The Google detail's accounts half (the real `CompanyAccountsSections`)
/// with two accounts and **Add an account** offering the assistant first,
/// over the detail's sync settings.
private struct GoogleDetailAgentScene: View {
    let harness: ConnectHarness

    private typealias Pres = CompanyConnectionsPresentation

    private static let own = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.google: ""])
    private static let companies = [CompaniesZoneScenes.acme, own]
    private static let accounts = [
        AccountRef(vendor: .google, accountID: 1, label: "alice@example.com", companySlug: "acme", status: "ok", error: ""),
        AccountRef(vendor: .google, accountID: 2, label: "alice@example.net", companySlug: "me", status: "ok", error: "")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            CompanyAccountsSections(
                vendor: .google,
                banner: nil,
                list: .groups(Pres.groups(vendor: .google, accounts: Self.accounts, companies: Self.companies) { _ in false }),
                emptyActions: Pres.detailActions(.google, companies: Self.companies, empty: true),
                addActions: Pres.detailActions(.google, companies: Self.companies, empty: false),
                connect: CompanyGroupConnect { _, _ in },
                agent: ConnectAgentEntry(harness: { _ in harness }, open: { _ in }),
                perform: { _ in },
                bannerAction: { _ in },
                tryAgain: {},
                row: row
            )
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

/// Onboarding step 2 from its own rows (`OnboardingConnectSourceRow`):
/// **Connect with Claude** first on every source and today's **Connect**
/// second; **Continue** stays the one prominent button.
private struct OnboardingConnectAgentScene: View {
    let harness: ConnectHarness

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
                ForEach(Self.sources, id: \.title) { source in
                    OnboardingConnectSourceRow(
                        letter: source.letter, title: source.title, subtitle: source.subtitle,
                        connect: {}, agent: (harness, {}))
                }
            }
            Label(ConnectAssistantPresentation.onboardingFootnote(harness), systemImage: "lock")
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
}
