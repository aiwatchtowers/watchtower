import SwiftUI
import WatchtowerCore

/// The current turn's steps above the live line (#2201 spec §1): the newest
/// six rows in a fixed six-row slot (fewer steps bottom-aligned), with an
/// "N earlier steps" line above them when more happened. No scrolling.
struct WorkchatStepsList: View {
    let slot: WorkchatLivePresentation.StepsSlot

    private static let height = WorkchatLivePresentation.stepsHeight(rowHeight: ListLayout.lineMinHeight)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let earlier = slot.earlierLine {
                Text(earlier).foregroundStyle(.tertiary).frame(height: ListLayout.lineMinHeight)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(slot.rows) { row in stepRow(row) }
            }
            .frame(height: Self.height, alignment: .bottom)
        }
        .font(.caption)
        // Quiet: no card, a thin rule under the live line's chevron.
        .padding(.leading, Spacing.medium)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: Stroke.hairline * 2)
        }
        .padding(.leading, Spacing.large + IconSize.header / 2)
        .padding(.trailing, Spacing.large)
        .padding(.bottom, Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(slot.title)
    }

    private func stepRow(_ row: WorkchatLivePresentation.StepRow) -> some View {
        HStack(spacing: Spacing.compact) {
            Group {
                if row.running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: row.symbol)
                }
            }
            .frame(width: IconSize.header)
            Text(row.summary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.summary)
            Spacer(minLength: Spacing.compact)
            if let time = row.time {
                Text(time)
                    .monospacedDigit()
                    .foregroundStyle(row.running ? .secondary : .tertiary)
            }
        }
        .foregroundStyle(row.running ? .primary : .tertiary)
        .frame(height: ListLayout.lineMinHeight)
    }
}
