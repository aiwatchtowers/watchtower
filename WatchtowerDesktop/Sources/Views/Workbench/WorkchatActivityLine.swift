import SwiftUI
import WatchtowerCore

/// The live line between the Workchat feed and the composer: a symbol, the
/// agent's current step and how long it has lasted. Fixed height, so the
/// feed does not jump when it comes and goes.
struct WorkchatActivityLine: View {
    let line: WorkchatActivityPresenter.Line

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: line.symbol)
                .symbolEffect(.pulse)
                .frame(width: 14)
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer(minLength: Spacing.compact)
            if let since = line.since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.large)
        .frame(height: 22)
        .animation(.default, value: line)
        .accessibilityElement(children: .combine)
    }

    /// `m:ss`; a start in the future (clock skew) shows 0:00.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
