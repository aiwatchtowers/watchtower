import SwiftUI
import WatchtowerCore

extension StatusBadge {
    /// Spec §12.1's colours: succeeded green, running/waiting blue,
    /// failed/timed_out/expired red, budget_exceeded orange, cancelled grey.
    var color: Color {
        switch self {
        case .green: .green
        case .blue: .blue
        case .red: .red
        case .orange: .orange
        case .grey: .secondary
        }
    }
}

/// A run status as the list and History show it: "● Succeeded".
struct AutomationStatusPill: View {
    let pill: AutomationCardPresentation.Pill

    var body: some View {
        Text("● \(pill.text)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(pill.badge.color)
            .lineLimit(1)
    }
}

/// A row badge — **Needs your confirmation**, **Auto paused**, **Disabled**,
/// **Parse error** — as a tinted capsule.
struct AutomationRowBadgeView: View {
    let badge: AutomationRowBadge

    var body: some View {
        Text(AutomationCardPresentation.badgeText(badge))
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var tint: Color {
        switch badge {
        case .needsConfirmation, .autoPaused: .orange
        case .disabled: .secondary
        case .parseError: .red
        }
    }
}
