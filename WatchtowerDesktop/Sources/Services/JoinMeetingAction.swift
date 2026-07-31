import AppKit
import Foundation

/// Shared Join-meeting action behind every "Join" button (event row, sidebar
/// next-event block): opens the event's conference link and — when
/// "Auto-record on join" is enabled and the recorder is free — starts an
/// event-linked recording.
///
/// Joining the meeting must never be blocked by recorder problems: the URL
/// opens first, unconditionally, and a recording already in flight (this or
/// another event) is never interrupted or double-started — the single-slot
/// guard here mirrors `MeetingRecorderCenter.isBusy`.
@MainActor
enum JoinMeetingAction {
    /// `@AppStorage("calendar.autoRecordOnJoin")` in Settings; absent = true.
    static let autoRecordKey = "calendar.autoRecordOnJoin"

    /// `openURL` and `defaults` are injectable seams so tests neither drive
    /// `NSWorkspace` nor read the real preference.
    static func join(
        event: CalendarEvent,
        center: MeetingRecorderCenter,
        defaults: UserDefaults = .standard,
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) async {
        guard let url = event.conferenceLink else { return }
        openURL(url)

        let autoRecord = defaults.object(forKey: autoRecordKey) as? Bool ?? true
        guard autoRecord, !center.isBusy else { return }
        // A start failure surfaces through the Center's own error path
        // (RecordingIndicatorView) — the link has already opened above.
        await center.startRecording(eventID: event.id, title: event.title, config: .fromDefaults())
    }
}
