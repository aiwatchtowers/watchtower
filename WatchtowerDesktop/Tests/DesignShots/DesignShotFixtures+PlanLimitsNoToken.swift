import AppKit
import DesignKit
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// Design-only scenes for the plan limits without a token spec (#1885,
/// `docs/superpowers/specs/2026-11-17-plan-limits-without-token-design.md`).
/// Built from the production Plans pieces (`PlansProviderCard`,
/// `PlansChartCard`, `PlansScreenPresentation`, `PlansPopupPresentation`) on
/// `PlansShotFixtures` snapshots; only the Claude card's message comes from
/// `PlanLimitsNoTokenMockCopy`, because today's `errorText` words these codes
/// for Codex. Nothing here is wired into the app.
@MainActor
enum PlanLimitsNoTokenShotFixtures {
    enum Frame: String, CaseIterable {
        case cliMissing, cliOutdated, notSignedIn, apiKey, readFailed
    }

    static let now = PlansShotFixtures.now

    /// The stored Claude reason each frame shows.
    static func reason(_ frame: Frame) -> String {
        switch frame {
        case .cliMissing: "cli_missing"
        case .cliOutdated: "unsupported_cli"
        case .notSignedIn: "no_credentials"
        case .apiKey: "unsupported_auth"
        case .readFailed: "network"
        }
    }

    /// The Claude message the spec gives the frame; nil keeps production's.
    static func mockMessage(_ frame: Frame) -> String? {
        switch frame {
        case .cliMissing: PlanLimitsNoTokenMockCopy.cliMissing
        case .cliOutdated: PlanLimitsNoTokenMockCopy.cliOutdated
        case .notSignedIn: PlanLimitsNoTokenMockCopy.notSignedIn
        case .apiKey: PlanLimitsNoTokenMockCopy.apiKey
        case .readFailed: nil
        }
    }

    /// The Claude row as the daemon stores it: unavailable codes keep no
    /// visible numbers; a failed read keeps the last good ones (`error`).
    static func claudeStatus(_ frame: Frame) -> PlanUsageStatus {
        let good = PlansShotFixtures.snapshot(.claude)
        let failed = frame == .readFailed
        return PlanUsageStatus(state: failed ? "error" : "unavailable", reason: reason(frame),
                               plan: [.notSignedIn, .apiKey].contains(frame) ? "" : good.plan,
                               fetchedAt: good.fetchedAt.map { $0.addingTimeInterval(failed ? -1080 : 0) },
                               lastError: "", limits: good.limits, breakdown: good.breakdown, provider: .claude,
                               identityKnown: true, plot: good.plot, history: good.history,
                               publicationIntegrity: .verified)
    }

    static func model(_ frame: Frame) -> PlansScreenPresentation {
        PlansScreenPresentation(claude: claudeStatus(frame), codex: PlansShotFixtures.snapshot(.codex), now: now)
    }

    /// Production providers with the Claude summary replaced by the spec's copy.
    static func providers(_ frame: Frame) -> [PlansScreenProvider] {
        model(frame).providers.map { provider in
            guard provider.id == .claude, let message = mockMessage(frame) else { return provider }
            let card = provider.presentation
            return PlansScreenProvider(
                presentation: PlansProviderPresentation(provider: card.provider, title: card.title, plan: card.plan,
                                                        summary: message, freshness: card.freshness, action: card.action,
                                                        isRefreshing: card.isRefreshing, isStale: card.isStale,
                                                        limits: card.limits),
                status: provider.status, summaryNeeded: provider.summaryNeeded, hasError: provider.hasError)
        }
    }

    static func popupProviders(_ frame: Frame) -> (PlansPopupPresentation, [PlansPopupProvider]) {
        let popup = PlansPopupPresentation(screen: model(frame))
        let rows = popup.providers.map { row in
            guard row.id == .claude, let message = mockMessage(frame) else { return row }
            return PlansPopupProvider(id: row.id, title: row.title, plan: row.plan, freshness: row.freshness,
                                      message: message, messageTone: row.messageTone, action: row.action,
                                      canRefresh: row.canRefresh, compactUsage: row.compactUsage,
                                      primaryForecast: row.primaryForecast, primaryTone: row.primaryTone,
                                      groups: row.groups)
        }
        return (popup, rows)
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "plan-limits-nt-\(frame.rawValue)", size: NSSize(width: 1120, height: 900)) {
                AnyView(PlanLimitsNoTokenScreenMock(model: model(frame), providers: providers(frame)))
            }
        } + Frame.allCases.map { frame in
            DesignShot(name: "plan-limits-nt-menu-\(frame.rawValue)", size: NSSize(width: 420, height: 0)) {
                let (popup, rows) = popupProviders(frame)
                return AnyView(PlanLimitsNoTokenPopupMock(popup: popup, providers: rows)
                    .padding(Spacing.large).detailBackground())
            }
        }
    }
}

/// The Plans screen as `PlansContent` lays it out (header, summary, cards,
/// history), over providers the mock may reword.
private struct PlanLimitsNoTokenScreenMock: View {
    let model: PlansScreenPresentation
    let providers: [PlansScreenProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.wide) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(PlansScreenCopy.heading).font(.largeTitle.weight(.semibold))
                    Text(PlansScreenCopy.subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.refreshTitle, systemImage: "arrow.clockwise") {}.buttonStyle(.kitSecondary)
            }
            HStack(spacing: Spacing.medium) {
                Image(systemName: model.warning ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.warning ? Tone.warning : Tone.success)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(model.statusTitle).font(.callout.weight(.semibold))
                    Text(model.statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(Spacing.large).background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
            grid { ForEach(providers) { PlansProviderCard(provider: $0, enabled: true) {} } }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(PlansScreenCopy.historyTitle(.weekly)).font(.title3.weight(.semibold))
                Text(PlansScreenCopy.historyNote).font(.caption).foregroundStyle(.secondary)
            }
            grid { ForEach(providers) { PlansChartCard(provider: $0, period: .weekly, now: model.now) } }
            Spacer(minLength: 0)
        }
        .padding(Spacing.wide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground()
        .controlSize(.small)
    }

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.large, alignment: .top), count: 2),
                  spacing: Spacing.large, content: content)
    }
}

/// The menu-bar popup as `PlansMenuPanel` lays it out, over rows the mock may reword.
private struct PlanLimitsNoTokenPopupMock: View {
    let popup: PlansPopupPresentation
    let providers: [PlansPopupProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack {
                Text(PlansPopupCopy.title).font(.headline)
                Spacer()
                Text(popup.freshness).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                if provider.id.subscription.layout == .compact { compact(provider) } else { grouped(provider) }
            }
            HStack {
                Button(PlansScreenCopy.open) {}.buttonStyle(.kitQuiet)
                Spacer()
                Button(popup.refreshTitle) {}.buttonStyle(.kitSecondary)
            }
        }
        .padding(Spacing.large)
        .frame(width: PlansLayout.menuWidth)
        .popoverSurface()
    }

    private func compact(_ provider: PlansPopupProvider) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack {
                Text(provider.title).font(.callout.weight(.semibold))
                if !provider.plan.isEmpty { Text(provider.plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let usage = provider.compactUsage { Text(usage).font(.caption).monospacedDigit() }
            }
            if let message = provider.message {
                Text(message).font(.caption).foregroundStyle(color(provider.messageTone)).fixedSize(horizontal: false, vertical: true)
                Button(provider.action) {}.buttonStyle(.kitQuiet)
            } else if let forecast = provider.primaryForecast {
                Text(forecast).font(.caption).foregroundStyle(color(provider.primaryTone))
            }
        }.padding(Spacing.medium).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func grouped(_ provider: PlansPopupProvider) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Text(provider.title).font(.headline)
                if !provider.plan.isEmpty { Text(provider.plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            ForEach(provider.groups) { group in
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Text(group.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(group.quotas) { quota in
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            HStack(spacing: Spacing.regular) {
                                Text(quota.duration).font(.caption.weight(.semibold))
                                Spacer(minLength: Spacing.small)
                                Text(quota.reset).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                Text(quota.percent).font(.caption.weight(.semibold)).monospacedDigit()
                            }
                            if let forecast = quota.forecast {
                                Text(forecast)
                                    .font(.caption)
                                    .foregroundStyle(color(quota.tone))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                    }
                }
            }
        }
    }

    private func color(_ tone: PlanUsageTone) -> Color {
        switch tone {
        case .critical: Tone.error
        case .warning: Tone.warning
        case .normal: Tone.success
        case .muted: Tone.status("gray")
        }
    }
}
