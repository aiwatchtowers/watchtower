import SwiftUI
import WatchtowerCore

// MARK: - IdeaRow
//
// One row in the Ideas registry's master list. Mirrors SituationRow's shape:
// kind glyph + 2-line title, an orange dot when the idea needs a second look,
// trailing relative last-mention date.
struct IdeaRow: View {
    let idea: Idea

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kindGlyph)
                .font(.caption)
                .foregroundStyle(kindColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(idea.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if idea.needsReview {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                        Text(idea.reviewReason.isEmpty ? "Needs review" : idea.reviewReason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            if let date = TimeFormatting.parseISO(idea.lastMentionAt) {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var kindGlyph: String {
        switch idea.kind {
        case .idea: return "lightbulb"
        case .decision: return "checkmark.seal"
        case .note: return "note.text"
        }
    }

    private var kindColor: Color {
        switch idea.kind {
        case .idea: return .yellow
        case .decision: return .purple
        case .note: return .secondary
        }
    }
}
