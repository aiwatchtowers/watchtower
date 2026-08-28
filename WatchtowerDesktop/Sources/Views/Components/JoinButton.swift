import SwiftUI
import WatchtowerCore

/// Shared chrome for the "Join" meeting button (event row, sidebar next-event
/// block). The load-bearing logic — open link, auto-record gating — stays in
/// `JoinMeetingAction`; this only deduplicates the Label/small look.
/// `prominent` (imminent/ongoing meetings in the event row; always in the
/// sidebar) makes it a filled accent button; otherwise a plain bordered one.
struct JoinButton: View {
    let event: CalendarEvent
    let center: MeetingRecorderCenter
    var prominent: Bool = true

    var body: some View {
        // A filled `.borderedProminent` for the imminent/ongoing case: the
        // earlier `.bordered` + `.tint(.accentColor)` only recolored the label,
        // which on macOS reads as a dimmed, inactive secondary control — the
        // opposite of the intended prominence for "join this meeting now".
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button {
            Task { await JoinMeetingAction.join(event: event, center: center) }
        } label: {
            Label("Join", systemImage: "video")
                .font(.caption)
        }
        .controlSize(.small)
        .tint(prominent ? Color.accentColor : nil)
        .help("Open the meeting link")
    }
}
