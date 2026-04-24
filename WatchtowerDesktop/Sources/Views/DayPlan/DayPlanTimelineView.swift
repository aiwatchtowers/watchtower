import SwiftUI

struct DayPlanTimelineView: View {
    let items: [DayPlanItem]
    let onToggle: (DayPlanItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                timelineRow(item)
                Divider()
                    .padding(.leading, 80)
            }
        }
    }

    private func timelineRow(_ item: DayPlanItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Time range (fixed width, monospaced)
            Text(item.timeRange ?? "")
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
                .padding(.top, 2)

            // Colored vertical bar
            RoundedRectangle(cornerRadius: 2)
                .fill(sourceColor(item.sourceType))
                .frame(width: 3)
                .padding(.vertical, 2)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .lineLimit(2)

                if let rationale = item.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)

            Spacer()

            // Toggle button (hidden for read-only calendar items)
            if !item.isReadOnly {
                Button(action: { onToggle(item) }) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isDone ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func sourceColor(_ sourceType: DayPlanItemSourceType) -> Color {
        switch sourceType {
        case .calendar:          return .gray
        case .focus:             return .blue
        case .task:              return .green
        case .jira:              return .purple
        case .briefingAttention: return .yellow
        case .manual:            return .orange
        }
    }
}
