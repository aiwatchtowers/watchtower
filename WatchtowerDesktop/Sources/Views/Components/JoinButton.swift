import SwiftUI

/// Shared chrome for the "Join" meeting button (event row, sidebar next-event
/// block). The load-bearing logic — open link, auto-record gating — stays in
/// `JoinMeetingAction`; this only deduplicates the Label/bordered/small look.
/// `prominent` tints the button with the accent color (imminent/ongoing
/// meetings in the event row; always in the sidebar).
struct JoinButton: View {
    let event: CalendarEvent
    let center: MeetingRecorderCenter
    var prominent: Bool = true

    var body: some View {
        Button {
            Task { await JoinMeetingAction.join(event: event, center: center) }
        } label: {
            Label("Join", systemImage: "video")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(prominent ? Color.accentColor : nil)
        .help("Open the meeting link")
    }
}
