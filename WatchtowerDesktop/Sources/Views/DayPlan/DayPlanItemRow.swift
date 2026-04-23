import SwiftUI

struct DayPlanItemRow: View {
    let item: DayPlanItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox toggle
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Title + rationale
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .strikethrough(item.isDone, color: .secondary)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .lineLimit(2)

                    if item.isManual {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                if let rationale = item.rationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Priority badge
            if let priority = item.priority {
                priorityBadge(priority)
            }

            // Context menu trigger (3-dot)
            Menu {
                if item.isDone {
                    Button("Mark Pending") { onToggle() }
                } else {
                    Button("Mark Done") { onToggle() }
                }
                Divider()
                Button("Delete", role: .destructive) { onDelete() }
                    .disabled(item.isReadOnly)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func priorityBadge(_ priority: String) -> some View {
        Text(priority.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor(priority).opacity(0.15), in: Capsule())
            .foregroundStyle(priorityColor(priority))
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high":   return .red
        case "medium": return .orange
        case "low":    return .blue
        default:       return .secondary
        }
    }
}
