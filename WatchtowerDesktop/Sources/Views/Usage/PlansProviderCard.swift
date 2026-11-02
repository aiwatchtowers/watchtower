import DesignKit
import SwiftUI
import WatchtowerCore

struct PlansProviderCard: View {
    let provider: PlansScreenProvider
    let enabled: Bool
    let refresh: () -> Void
    private var card: PlansProviderPresentation { provider.presentation }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack {
                Image(systemName: provider.id == .claude ? "sparkle" : "terminal").foregroundStyle(providerColor)
                Text(card.title).font(.headline)
                Text(provider.planLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if card.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(card.isStale ? Tone.warning : Tone.success)
                        .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                }
            }
            if let primary = provider.primary {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text(primary.percent).font(.largeTitle.weight(.semibold)).monospacedDigit()
                    Text(PlansScreenCopy.used).foregroundStyle(.secondary)
                    Spacer()
                    Text(primary.title).font(.caption).foregroundStyle(.secondary)
                }
                if let percent = rawPercent(primary) { PlansUsageBar(percent: percent, color: providerColor) }
                Text(primary.reset).font(.caption).foregroundStyle(.secondary)
                Label(primary.forecast, systemImage: plansForecastIcon(primary))
                    .font(.callout.weight(.medium)).foregroundStyle(plansForecastColor(primary))
                if let session = provider.session, session.key != primary.key {
                    HStack {
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            Text(session.title).font(.caption).foregroundStyle(.secondary)
                            Text(session.reset).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.percent).font(.title3.weight(.medium)).monospacedDigit()
                    }.padding(Spacing.medium).background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.control))
                }
            }
            if provider.showsSummary { Text(card.summary).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(card.freshness).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(card.action, action: refresh).buttonStyle(.kitQuiet).disabled(card.isRefreshing || !enabled)
            }
        }.padding(Spacing.page)
        .frame(maxWidth: .infinity, minHeight: PlansLayout.providerMinimumHeight, alignment: .topLeading)
        .card()
    }

    private var providerColor: Color { Tone.status(provider.id == .claude ? "purple" : "teal") }
    private func rawPercent(_ item: PlansLimitPresentation) -> Double? {
        provider.status?.limits.first { $0.key == item.key }?.percent
    }
}

struct PlansUsageBar: View {
    let percent: Double
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Fill.hover)
                Capsule().fill(color).frame(width: proxy.size.width * percent / 100)
            }
        }.frame(height: PlansLayout.progressHeight)
    }
}

func plansForecastColor(_ item: PlansLimitPresentation) -> Color {
    switch item.tone {
    case .critical: Tone.error
    case .warning: Tone.warning
    case .normal: item.line == nil ? Tone.status("gray") : Tone.success
    case .muted: Tone.status("gray")
    }
}

func plansForecastIcon(_ item: PlansLimitPresentation) -> String {
    item.tone == .warning || item.tone == .critical ? "exclamationmark.triangle" : item.line == nil ? "clock" : "checkmark.circle"
}
