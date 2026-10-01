import SwiftUI
import WatchtowerCore

/// Shared chrome for the "Join" meeting button (event row, meeting detail,
/// sidebar next-event block). The load-bearing logic — open link,
/// auto-record gating — stays in `JoinMeetingAction`; this only deduplicates
/// the look. `prominent` (imminent/ongoing meetings in the event row; always
/// in the sidebar) makes it a filled blue button; otherwise a plain one.
struct JoinButton: View {
    let event: CalendarEvent
    let center: MeetingRecorderCenter
    var prominent: Bool = true

    var body: some View {
        Button {
            Task { await JoinMeetingAction.join(event: event, center: center) }
        } label: {
            Label("Join", systemImage: "video")
        }
        .buttonStyle(JoinButtonStyle(prominent: prominent))
        .help("Open the meeting link")
    }
}

/// The Join button's own drawing. The system `.borderedProminent` turned
/// grey with a grey label in an inactive window and over the sidebar's
/// vibrancy (and a Graphite accent colour greys it out too), so the label
/// was unreadable. This style paints an opaque fill and a fixed label colour
/// that read the same in light and dark mode, key or not.
struct JoinButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(prominent ? Color(nsColor: .systemBlue) : Color(nsColor: .controlColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: prominent ? 0 : 0.5)
            )
            .opacity(configuration.isPressed ? 0.75 : isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 5))
            // Keep the label at its intrinsic size: in a tight HStack (the
            // sidebar's next-meeting card) the button otherwise competes with
            // its neighbouring Text for width and gets compressed to "J…".
            .fixedSize()
    }
}
