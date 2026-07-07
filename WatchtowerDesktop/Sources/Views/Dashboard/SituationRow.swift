import SwiftUI

// MARK: - SituationRow
//
// One row in the Dashboard's master list (left of the split). Mirrors the
// visual language of CatchUpThemeRow: priority dot + title + kind badge, with
// a trailing relative timestamp.
struct SituationRow: View {
    let situation: Situation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(situation.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                kindBadge
            }

            Spacer(minLength: 4)

            if let date = situation.lastSignalDate {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var kindBadge: some View {
        let info = kindBadgeInfo
        return Text(info.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(info.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(info.color.opacity(0.12), in: Capsule())
    }

    private var kindBadgeInfo: (label: String, color: Color) {
        switch situation.kind {
        case .external:      return ("Signal", .secondary)
        case .targetUpdate:  return ("Target", .blue)
        case .trackUpdate:   return ("Track", .purple)
        case .mixed:         return ("Mixed", .orange)
        }
    }

    private var priorityColor: Color {
        switch situation.priority {
        case "high": return .red
        case "medium": return .orange
        default: return .blue
        }
    }
}
