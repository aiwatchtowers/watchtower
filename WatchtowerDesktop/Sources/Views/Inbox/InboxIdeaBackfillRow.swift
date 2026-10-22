import SwiftUI
import WatchtowerCore

/// The date range Find Ideas in Past Messages… mines.
struct InboxIdeaBackfillRange: Equatable {
    var from: Date
    var to: Date

    /// The range that is mining (or last mined), else the last two weeks:
    /// a row reopened mid-run shows what is actually running.
    @MainActor static func initial(_ ideas: IdeasViewModel, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let twoWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -2, to: now) ?? now
        return Self(from: ideas.backfillFrom ?? twoWeeksAgo, to: ideas.backfillTo ?? now)
    }
}

/// The Ideas filter's inline **Find Ideas in Past Messages…** row (R9,
/// replaces `IdeaBackfillSheet`): presets, the calendar range, **Find
/// Ideas** and **Close**; while mining, the elapsed time and **Stop**, then
/// the outcome. Mining runs `watchtower ideas mine --from --to` through
/// `IdeasViewModel.startBackfillTask`, which owns the run, so closing the row
/// (or leaving the Inbox) never stops it.
struct InboxIdeaBackfillRow: View {
    let ideas: IdeasViewModel
    @Binding var range: InboxIdeaBackfillRange
    let onClose: () -> Void

    /// A half-picked range has not reached `range` yet: Find Ideas waits.
    @State private var pendingAnchor = false

    private enum Preset: CaseIterable {
        case twoWeeks, month, quarter

        var title: String {
            switch self {
            case .twoWeeks: "2 weeks"
            case .month: "Month"
            case .quarter: "Quarter"
            }
        }

        func from(_ now: Date, calendar: Calendar = .current) -> Date {
            let date: Date?
            switch self {
            case .twoWeeks: date = calendar.date(byAdding: .weekOfYear, value: -2, to: now)
            case .month: date = calendar.date(byAdding: .month, value: -1, to: now)
            case .quarter: date = calendar.date(byAdding: .month, value: -3, to: now)
            }
            return date ?? now
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("Find Ideas in Past Messages")
                .font(.callout.weight(.semibold))
            Text("Mine ideas, notes, and decisions from a past date range — the regular pass only looks at recent activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                ForEach(Preset.allCases, id: \.self) { preset in
                    Button(preset.title) {
                        let now = Date()
                        range = InboxIdeaBackfillRange(from: preset.from(now), to: now)
                    }
                    .buttonStyle(.kitSecondary)
                }
            }
            .disabled(ideas.isBackfilling)
            Text("\(Self.rangeFormatter.string(from: range.from)) — \(Self.rangeFormatter.string(from: range.to))")
                .font(.callout)
            CalendarRangePicker(fromDate: $range.from, toDate: $range.to,
                                hasPendingAnchor: $pendingAnchor, isDisabled: ideas.isBackfilling)
            status
            HStack(spacing: Spacing.regular) {
                Spacer()
                if ideas.isBackfilling {
                    Button("Stop") { ideas.cancelBackfill() }
                        .buttonStyle(.kitSecondary)
                }
                Button("Close", action: onClose)
                    .buttonStyle(.kitQuiet)
                Button("Find Ideas", action: start)
                    .buttonStyle(.kitPrimary)
                    .disabled(ideas.isBackfilling || pendingAnchor)
            }
        }
        .padding(Spacing.medium)
        .card()
    }

    /// Running, then the outcome; an error wins over an older summary (the
    /// view model clears neither on failure).
    @ViewBuilder
    private var status: some View {
        if ideas.isBackfilling {
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text("Mining ideas…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let startedAt = ideas.backfillStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.elapsedString(from: startedAt, to: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } else if let error = ideas.backfillError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Tone.warning)
                .textSelection(.enabled)
        } else if let summary = ideas.backfillSummary {
            Label(summary, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Starts mining the shown range; the row stays open to show the run.
    func start() {
        ideas.startBackfillTask(from: range.from, to: range.to)
    }

    static func elapsedString(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static let rangeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt
    }()
}
