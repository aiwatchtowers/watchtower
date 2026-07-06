import SwiftUI

/// Capsule badge shared across the tab rows: status and priority on Inbox,
/// priority and due date on Tasks, the pending overlay chips.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Maps the Kit models' string color names (`statusColor` / `priorityColor`)
/// to SwiftUI colors. Every name the models can emit is mapped explicitly —
/// "secondary" included — so a known string never silently degrades to the
/// gray default; the default arm is only for future/unknown names.
func color(_ name: String) -> Color {
    switch name {
    case "red": return .red
    case "orange": return .orange
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "gray": return .gray
    case "secondary": return .secondary
    default: return .gray
    }
}
