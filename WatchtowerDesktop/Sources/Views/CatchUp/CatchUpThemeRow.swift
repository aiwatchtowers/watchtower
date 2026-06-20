import SwiftUI

// MARK: - CatchUpThemeRow
//
// One row in the streaming left-hand theme list. Mirrors the visual language of
// the inbox/track list rows: a priority dot, the theme title, and trailing
// status badges (spinner while expanding, needs-you flag, reviewed checkmark).
struct CatchUpThemeRow: View {
    let theme: CatchUpTheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)

            Text(displayTitle)
                .font(.subheadline)
                .fontWeight(theme.isPending ? .medium : .regular)
                .foregroundStyle(theme.isReviewed ? .secondary : .primary)
                .lineLimit(2)

            Spacer(minLength: 4)

            trailingBadge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Title

    private var displayTitle: String {
        theme.title.isEmpty ? "Untitled theme" : theme.title
    }

    // MARK: - Trailing badge

    @ViewBuilder
    private var trailingBadge: some View {
        if theme.isExpanding {
            ProgressView()
                .controlSize(.small)
        } else if theme.isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .help("Expansion failed — regenerate to retry")
        } else if theme.isSnoozed {
            Image(systemName: "moon.zzz.fill")
                .font(.caption2)
                .foregroundStyle(.purple)
        } else if theme.isReviewed {
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if theme.needsYou {
            Image(systemName: "person.fill.questionmark")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("Needs your input")
        }
    }

    // MARK: - Priority

    private var priorityColor: Color {
        switch theme.priority {
        case "high": return .red
        case "low": return .blue
        default: return .orange
        }
    }
}
