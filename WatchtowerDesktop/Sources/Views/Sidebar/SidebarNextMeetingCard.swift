import SwiftUI
import WatchtowerCore

/// The sidebar footer's next calendar event: its title (two lines, the full
/// title on hover — one line cut it to "SYNC | C…"), when it starts
/// (`MeetingCountdown`), and Join when it has a link.
struct SidebarNextMeetingCard: View {
    let event: CalendarEvent
    let center: MeetingRecorderCenter

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(event.title)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingCountdown.text(start: event.startDate, now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if event.conferenceLink != nil {
                Spacer(minLength: 4)
                JoinButton(event: event, center: center)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
