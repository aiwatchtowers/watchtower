import SwiftUI
import WatchtowerCore

/// The live line between the Workchat feed and the composer: a symbol, the
/// agent's current step and how long it has lasted. The row keeps its height
/// when there is no line (a blank caption line in the same frame), so the
/// feed does not jump when the line comes and goes.
struct WorkchatActivityLine: View {
    let line: WorkchatActivityPresenter.Line?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.compact) {
            if let line {
                content(line)
            } else {
                Text(verbatim: " ").accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.toggle, value: line)
    }

    private func content(_ line: WorkchatActivityPresenter.Line) -> some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: line.symbol)
                // Reduce Motion keeps the glyph still.
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .frame(width: IconSize.header)
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
        .accessibilityElement(children: .combine)
    }

    /// `m:ss`; a start in the future (clock skew) shows 0:00.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
