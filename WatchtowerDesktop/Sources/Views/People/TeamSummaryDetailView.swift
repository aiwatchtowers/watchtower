import SwiftUI
import WatchtowerCore

/// The Team Summary: what the team worked on and tips for working with it.
/// No list of people who "need attention" (#1769, A12).
struct TeamSummaryDetailView: View {
    let summary: PeopleCardSummary
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header
                if !summary.summary.isEmpty {
                    Text(summary.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                tipsSection
                metadata
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .detailBackground()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(PeopleCardCopy.teamSummaryTitle).font(.title2.weight(.semibold))
            Text(PeopleCardCopy.period(
                from: Date(timeIntervalSince1970: summary.periodFrom),
                to: Date(timeIntervalSince1970: summary.periodTo)
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.medium)
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.kitIcon(isOn: false))
                    .help(PeopleCardCopy.close)
            }
        }
    }

    @ViewBuilder
    private var tipsSection: some View {
        let items = summary.parsedTips
        if !items.isEmpty {
            PeopleSection(title: PeopleCardCopy.tipsTitle, icon: "lightbulb") {
                ForEach(items, id: \.self) { tip in
                    Text("• " + tip).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Model, tokens and cost of the run that wrote the summary.
    @ViewBuilder
    private var metadata: some View {
        if !summary.model.isEmpty {
            Text(PeopleCardCopy.runLine(
                model: summary.model,
                tokens: summary.inputTokens + summary.outputTokens,
                costUSD: summary.costUSD
            ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}
