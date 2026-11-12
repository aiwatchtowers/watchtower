import SwiftUI
import WatchtowerCore

/// The Morning brief's day controls on its pane header (spec "One brief
/// row"): the ‹ date › stepper and **History**. Every press is the owner's
/// pick (`ActionStripViewModel.stepBrief`/`showBriefDay`), which marks the
/// day's briefing read; drawing them writes nothing (STRIP-02).
struct InboxBriefStepper: View {
    /// The shown day, "yyyy-MM-dd".
    let date: String
    let canStepOlder: Bool
    let canStepNewer: Bool
    let onStep: (InboxBriefDays.Step) -> Void

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Button { onStep(.older) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.kitIcon(isOn: false))
                .disabled(!canStepOlder)
                .help("Previous day")
                .accessibilityLabel("Previous day")
                .accessibilityIdentifier("inbox.brief.older")
            Text(InboxDayPane.dateLabel(date))
                .font(.caption.monospacedDigit())
            Button { onStep(.newer) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.kitIcon(isOn: false))
                .disabled(!canStepNewer)
                .help("Next day")
                .accessibilityLabel("Next day")
                .accessibilityIdentifier("inbox.brief.newer")
        }
    }
}

/// **History**: a popover over the last 30 days with a brief or a plan
/// (`InboxBriefDays.history`), unread ones marked.
struct InboxBriefHistoryButton: View {
    let days: [InboxDayCard]
    /// The shown day, "yyyy-MM-dd".
    let shownDate: String
    @Binding var isShown: Bool
    let onPick: (String) -> Void

    var body: some View {
        Button("History") { isShown = true }
            .buttonStyle(.kitSecondary)
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                InboxBriefHistoryList(days: days, shownDate: shownDate, onPick: onPick).popoverSurface()
            }
            .accessibilityIdentifier("inbox.brief.history")
    }
}

/// History's list: one row per day, newest first, an accent dot on a day
/// whose briefing is unread. A pick opens that day (and closes the popover:
/// `showBriefDay` clears `briefHistoryShown`).
struct InboxBriefHistoryList: View {
    let days: [InboxDayCard]
    let shownDate: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if days.isEmpty {
                Text("No briefs in the last \(InboxBriefDays.window) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.date) { day in
                Button { onPick(day.date) } label: { row(day) }
                    .buttonStyle(.plain)
                    .accessibilityValue(day.isUnread ? "Unread" : "")
            }
        }
        .frame(minWidth: ListLayout.dateColumn + ListLayout.markColumn, alignment: .leading)
        .controlSize(.small)
        .padding(Spacing.regular)
    }

    private func row(_ day: InboxDayCard) -> some View {
        HStack(spacing: Spacing.regular) {
            Circle()
                .fill(day.isUnread ? Color.accentColor : Color.clear)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                .accessibilityIdentifier(day.isUnread ? "inbox.brief.history.unread" : "inbox.brief.history.read")
            Text(InboxDayPane.dateLabel(day.date))
                .font(.callout.monospacedDigit())
            Spacer(minLength: 0)
        }
        .frame(minHeight: ListLayout.rowMinHeight)
        .padding(.horizontal, Spacing.regular)
        .contentShape(Rectangle())
        .kitRow(isSelected: day.date == shownDate)
    }
}
