import DesignKit
import SwiftUI
import WatchtowerCore

/// Production content, also rendered on synthetic snapshots by DesignShotCatalog.
struct PlansContent: View {
    let model: PlansScreenPresentation
    @Binding var period: PlansPeriod
    @Binding var showInMenuBar: Bool
    let refresh: (PlanUsageProvider) -> Void
    let refreshAll: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.wide) {
                    header
                    if !model.hasLimits { emptyState } else {
                        summary
                        LazyVGrid(columns: columns(geometry.size.width), spacing: Spacing.large) {
                            ForEach(model.providers) { provider in
                                PlansProviderCard(provider: provider, enabled: model.enabled) { refresh(provider.id) }
                            }
                        }
                        historyHeader
                        LazyVGrid(columns: columns(geometry.size.width), spacing: Spacing.large) {
                            ForEach(model.providers) { PlansChartCard(provider: $0, period: period, now: model.now) }
                        }
                        if model.hasDetails { details(width: geometry.size.width) }
                    }
                    HStack {
                        Image(systemName: "menubar.rectangle").foregroundStyle(.secondary)
                        Text(PlansScreenCopy.menu).font(.callout)
                        Spacer()
                        Toggle(PlansScreenCopy.menu, isOn: $showInMenuBar).labelsHidden().toggleStyle(.switch)
                    }.padding(Spacing.large).card()
                    Text(PlansScreenCopy.footer).font(.caption).foregroundStyle(.secondary)
                }
                .padding(Spacing.wide)
                .frame(maxWidth: PlansLayout.maximumWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }.detailBackground().controlSize(.small)
    }

    private func columns(_ width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Spacing.large, alignment: .top),
              count: width < PlansLayout.twoColumnWidth ? 1 : 2)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(PlansScreenCopy.heading).font(.largeTitle.weight(.semibold))
                Text(PlansScreenCopy.subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.medium)
            Button(model.refreshTitle, systemImage: "arrow.clockwise", action: refreshAll)
                .buttonStyle(.kitSecondary).disabled(model.isRefreshing || !model.enabled)
        }
    }

    private var summary: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: summarySymbol)
                .foregroundStyle(model.warning ? Tone.warning : model.hasUnavailableForecast ? Tone.status("gray") : Tone.success)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(model.statusTitle).font(.callout.weight(.semibold))
                Text(model.statusDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(Spacing.large).background(Fill.rest, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    private var summarySymbol: String {
        if model.isRefreshing { return "arrow.triangle.2.circlepath" }
        if model.warning { return "exclamationmark.triangle" }
        return model.hasUnavailableForecast ? "clock" : "checkmark.circle"
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.large) {
            if model.isLoading {
                ProgressView()
            } else {
                Image(systemName: model.warning ? "exclamationmark.triangle" : "chart.xyaxis.line")
                    .font(.largeTitle).foregroundStyle(model.warning ? Tone.warning : Tone.status("teal"))
            }
            Text(model.statusTitle).font(.title2.weight(.semibold))
            Text(model.statusDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.isLoading {
                ForEach(model.providers) { provider in
                    VStack(spacing: Spacing.small) {
                        Text(provider.presentation.title).font(.callout.weight(.medium))
                        Text(provider.presentation.summary).font(.caption).foregroundStyle(.secondary)
                        Button(PlansScreenCopy.providerAction(provider.presentation)) { refresh(provider.id) }
                            .buttonStyle(.kitSecondary).disabled(provider.presentation.isRefreshing || !model.enabled)
                    }
                }
            }
        }.padding(Spacing.hero).frame(maxWidth: .infinity, minHeight: PlansLayout.emptyHeight).card()
    }

    private var historyHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(PlansScreenCopy.historyTitle(period)).font(.title3.weight(.semibold))
                Text(PlansScreenCopy.historyNote).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            KitSegmentedPicker(title: PlansScreenCopy.periodTitle, selection: $period,
                               segments: PlansPeriod.allCases.map { KitSegment(value: $0, title: $0.title) })
        }
    }

    private func details(width: CGFloat) -> some View {
        LazyVGrid(columns: columns(width), alignment: .leading, spacing: Spacing.large) {
            if model.providers.contains(where: { !$0.otherLimits.isEmpty }) {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text(PlansScreenCopy.otherLimits).font(.headline)
                    ForEach(model.providers.filter { !$0.otherLimits.isEmpty }) { provider in
                        ForEach(provider.otherLimits, id: \.key) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: Spacing.small) {
                                    Text(provider.presentation.title + " · " + item.title).font(.callout)
                                    Text(item.forecast).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.percent).monospacedDigit()
                            }
                        }
                    }
                }
            }
            if let claude = model.providers.first(where: { $0.id == .claude }),
               let rows = claude.status?.breakdown, !rows.isEmpty, !claude.presentation.limits.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text(PlansScreenCopy.breakdown).font(.headline)
                    ForEach(rows) { row in
                        HStack { Text(row.label); Spacer(); Text(PlanUsagePresentation.percentText(row.percent)).monospacedDigit() }
                            .font(.caption)
                    }
                }
            }
        }.padding(Spacing.page).card()
    }
}
