import SwiftUI

/// One row of the wall — dispatches to `SituationRow` for situations and to a
/// shared compact layout (icon + title + badge + relative time) for the rest,
/// mirroring `SituationRow`'s visual language.
struct FeedRow: View {
    let entry: FeedEntry

    var body: some View {
        switch entry.content {
        case .situation(let situation):
            SituationRow(situation: situation)
        case .meeting(let event, _):
            GenericFeedRow(icon: "calendar", tint: .blue, title: event.title,
                           badge: "Meeting", date: event.startDate, isSeen: entry.item.isSeen)
        case .briefing(let briefing):
            GenericFeedRow(icon: "sunrise", tint: .orange, title: "Briefing — \(briefing.dateLabel)",
                           badge: "Briefing", date: entry.item.eventDate, isSeen: entry.item.isSeen)
        case .meetingRecap(let recap, let event):
            GenericFeedRow(icon: "text.badge.checkmark", tint: .green,
                           title: event?.title ?? recap.eventID,
                           badge: "Recap", date: entry.item.eventDate, isSeen: entry.item.isSeen)
        case .dayPlan(let plan):
            GenericFeedRow(icon: "list.bullet.rectangle", tint: .purple,
                           title: "Day plan — \(plan.planDate)",
                           badge: "Plan", date: entry.item.eventDate, isSeen: entry.item.isSeen)
        }
    }
}

/// Shared compact row for non-situation feed types. Unseen items render the
/// title semibold, echoing unread affordances elsewhere in the app.
struct GenericFeedRow: View {
    let icon: String
    let tint: Color
    let title: String
    let badge: String
    let date: Date?
    let isSeen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSeen ? .regular : .semibold)
                    .lineLimit(2)
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 4)
            if let date {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
