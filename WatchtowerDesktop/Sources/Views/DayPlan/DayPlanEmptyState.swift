import SwiftUI
import WatchtowerCore

/// Day Plan with no plan for the date. A fresh install (no day plan at all)
/// gets the shared first-run empty state; an established one, whose day plan
/// rows make the feature ready, only says when today's comes (owner, ask
/// #299). Generate stays in the footer, and with no owner identity the way to
/// connect one is inside (OWNER-02).
struct DayPlanEmptyState: View {
    let owner: Owner
    let context: EmptyStateContext
    let openConnections: () -> Void

    /// OWNER-02: the empty state replaces the plan body only when there is no
    /// owner identity AND no plan — an existing plan stays readable.
    static func showsNoOwnerState(owner: Owner, hasPlan: Bool) -> Bool {
        !owner.isKnown && !hasPlan
    }

    static func todaysPlanLine(hour: Int) -> String {
        "Today's plan at or after \(String(format: "%02d:00", hour))"
    }

    var body: some View {
        if context.readiness(.dayPlan) == .ready {
            VStack(spacing: 12) {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                // No owner, no plan made (OWNER-02): no time promised then.
                if Self.showsNoOwnerState(owner: owner, hasPlan: false) {
                    NoOwnerEmptyState(openConnections: openConnections)
                } else {
                    Text(Self.todaysPlanLine(hour: context.dayPlanHour))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TabEmptyState(.dayPlan, context: context) {
                if Self.showsNoOwnerState(owner: owner, hasPlan: false) {
                    NoOwnerEmptyState(openConnections: openConnections)
                }
            }
        }
    }
}
