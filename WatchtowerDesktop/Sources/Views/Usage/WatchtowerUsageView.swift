import SwiftUI
import WatchtowerCore

/// Usage → "Watchtower": what Watchtower itself spends on AI, read from
/// `watchtower usage llm --json` on appear and every 60 s while visible
/// (spec 2026-10-27-llm-usage-ledger §6, mockup `docs/design/mockups/llm-usage/`).
struct WatchtowerUsageView: View {
    static let periodKey = "usage.watchtower.period"
    @AppStorage(Self.periodKey) private var period: LLMUsagePeriod = .sevenDays
    @State private var viewModel = LLMUsageViewModel(period: .sevenDays)

    var body: some View {
        WatchtowerUsageContent(screen: viewModel.screen(now: Date()), period: $period) {
            Task { await viewModel.load() }
        }
        .task(id: period) {
            viewModel.period = period
            await viewModel.refreshLoop(every: 60)
        }
    }
}

/// The tab drawn from one `LLMUsageScreen`: no CLI, so the design shots
/// render every state from fixtures.
struct WatchtowerUsageContent: View {
    let screen: LLMUsageScreen
    @Binding var period: LLMUsagePeriod
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch screen {
            case .loading:
                page(captions: []) {
                    UsageReportBody(report: LLMUsagePresentation.placeholder)
                        .redacted(reason: .placeholder)
                }
            case .emptyLedger:
                stateBody(EmptyStateCopy(
                    icon: "chart.bar", title: "Recording starts with the next AI call",
                    landsHere: "Every AI call Watchtower makes will show up here.",
                    feature: nil, primaryAction: nil))
            case let .failed(error):
                stateBody(EmptyStateCopy(
                    icon: "exclamationmark.triangle", title: "Couldn't load AI usage",
                    landsHere: error.subtitle, feature: nil, primaryAction: .tabAction(label: "Retry")))
            case let .report(report, recordingSince, refreshFailedAt):
                page(captions: [recordingSince, refreshFailedAt.map(LLMUsagePresentation.refreshFailedCaption)]
                    .compactMap { $0 }) {
                    UsageReportBody(report: report)
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var periodPicker: some View {
        KitSegmentedPicker(
            title: "Period",
            selection: $period,
            segments: LLMUsagePeriod.allCases.map { KitSegment(value: $0, title: $0.title) }
        )
    }

    private func page(captions: [String], @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack(spacing: Spacing.medium) {
                    periodPicker
                    Spacer()
                    ForEach(captions, id: \.self) { caption in
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                content()
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stateBody(_ copy: EmptyStateCopy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            periodPicker
                .padding(.horizontal, Spacing.page)
                .padding(.top, Spacing.page)
            FeatureEmptyState(
                copy: copy, readiness: nil, syncLine: nil, turnOnError: nil, isTurningOn: false,
                onAction: { action in
                    if case .tabAction = action { onRetry() }
                },
                extra: { EmptyView() }
            )
        }
    }
}

/// The report's cards: totals, Watchtower's own work, your automations, chats and workbenches.
private struct UsageReportBody: View {
    let report: LLMUsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            totalsCard
            processCard
            if !report.ownAutomations.rows.isEmpty {
                automationsCard
            }
            chatsCard
        }
    }

    // MARK: Totals

    private var totalsCard: some View {
        let totals = report.watchtower.totals
        let gaps = LLMUsagePresentation.gaps(totals)
        return VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .top, spacing: Spacing.wide) {
                stat("Calls", LLMUsagePresentation.calls(totals.calls))
                stat("Fresh input", LLMUsagePresentation.tokens(totals.input))
                stat("Cache", LLMUsagePresentation.tokens(totals.cacheRead + totals.cacheWrite))
                stat("Output", LLMUsagePresentation.tokens(totals.output))
                stat("API-equivalent", LLMUsagePresentation.cost(totals))
            }
            if !gaps.isEmpty {
                gapsLine(gaps)
                    .font(.caption)
            }
        }
        .usageCard()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func gapsLine(_ gaps: [LLMUsagePresentation.Gap]) -> Text {
        gaps.enumerated().reduce(Text("")) { line, item in
            let part = Text(item.element.text).foregroundStyle(item.element.isWarning ? Tone.warning : .secondary)
            return item.offset == 0 ? part : line + Text(" · ").foregroundStyle(.secondary) + part
        }
    }

    // MARK: Watchtower collecting and processing

    private var processCard: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            cardTitle("Watchtower collecting and processing")
            UsageTableRow(name: "Process", cells: ["Calls", "Tokens", "Output", "Cost", "Per call"], isHeader: true)
            ForEach(LLMUsagePresentation.sorted(report.watchtower.rows)) { row in
                UsageTableRow(
                    name: row.displayName,
                    cells: [
                        LLMUsagePresentation.calls(row.calls),
                        LLMUsagePresentation.tokens(row.tokens),
                        LLMUsagePresentation.tokens(row.output),
                        LLMUsagePresentation.cost(row.costUSD, isEstimate: row.costIsEstimate,
                                                  isLowerBound: row.costIsLowerBound),
                        LLMUsagePresentation.tokens(row.perCallTokens)
                    ],
                    isWarning: row.isUntagged
                )
                .help(help(for: row))
            }
            if report.watchtower.rows.isEmpty {
                Text("No AI calls in this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .usageCard()
    }

    private func help(for row: LLMUsagePurposeRow) -> String {
        let group = row.isUntagged ? "No purpose tag" : LLMPurposeNames.display(purpose: row.purpose).group
        return row.models.isEmpty ? group : "\(group) · \(row.models.joined(separator: ", "))"
    }

    // MARK: Your automations

    private var automationsCard: some View {
        let totals = report.ownAutomations.totals
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.small) {
                cardTitle("Your automations")
                Text("— \(LLMUsagePresentation.tokens(totals.tokens)) tokens · \(LLMUsagePresentation.cost(totals))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            UsageTableRow(name: "Automation", cells: ["Runs", "Calls", "Tokens", "Output", "Cost"], isHeader: true)
            ForEach(LLMUsagePresentation.sorted(report.ownAutomations.rows)) { row in
                UsageTableRow(name: row.name, cells: [
                    LLMUsagePresentation.calls(row.runs),
                    LLMUsagePresentation.calls(row.calls),
                    LLMUsagePresentation.tokens(row.tokens),
                    LLMUsagePresentation.tokens(row.output),
                    LLMUsagePresentation.cost(row.costUSD, isEstimate: row.costIsEstimate, isLowerBound: row.costIsLowerBound)
                ])
            }
        }
        .usageCard()
    }

    // MARK: Chats and workbenches

    private var chatsCard: some View {
        let workbenches = report.workbenches
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            cardTitle("Chats and workbenches")
            UsageTableRow(name: "Chats", cells: [
                "\(LLMUsagePresentation.tokens(report.chats.tokens)) tokens",
                LLMUsagePresentation.cost(report.chats)
            ])
            UsageTableRow(name: "Workbenches", detail: LLMUsagePresentation.workbenchDetail(workbenches), cells: [
                "\(LLMUsagePresentation.tokens(workbenches.totals.tokens)) tokens",
                LLMUsagePresentation.cost(workbenches.totals)
            ])
            if let note = LLMUsagePresentation.analyticsOffNote(workbenches.analyticsOff) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .usageCard()
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// One line of a usage table: the name on the left, the numbers in fixed
/// right-aligned columns. No dividers between rows (style guide).
private struct UsageTableRow: View {
    let name: String
    var detail: String?
    let cells: [String]
    var isHeader = false
    var isWarning = false

    var body: some View {
        HStack(spacing: Spacing.regular) {
            HStack(spacing: Spacing.compact) {
                Text(name)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: ListLayout.numberColumn, alignment: .trailing)
            }
        }
        .font(isHeader ? .caption : .callout)
        .foregroundStyle(isHeader ? AnyShapeStyle(.secondary) : isWarning ? AnyShapeStyle(Tone.warning) : AnyShapeStyle(.primary))
        .frame(minHeight: ListLayout.lineMinHeight)
    }
}

private extension View {
    func usageCard() -> some View {
        padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }
}
