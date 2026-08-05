import AppKit
import Foundation

/// Shared Join-meeting action behind every "Join" button (event row, sidebar
/// next-event block): opens the event's conference link and — when
/// "Auto-record on join" is enabled, the OS supports recording, and the
/// recorder is free — starts an event-linked recording.
///
/// Joining the meeting must never be blocked by recorder problems: the URL
/// opens first, unconditionally. Auto-record is skipped entirely when the
/// open itself fails (there is no meeting to record if the user never
/// joined), and a recording already being captured (this or another event) is
/// never interrupted or double-started — `MeetingRecorderCenter.isCapturing`
/// latches synchronously at start (`isStarting`), so the single-capture guard
/// holds even across rapid Joins on different surfaces. A previous recording
/// still being transcribed is not a reason to skip: post-processing is queued.
@MainActor
enum JoinMeetingAction {
    /// `@AppStorage("calendar.autoRecordOnJoin")` in Settings; absent = true.
    static let autoRecordKey = "calendar.autoRecordOnJoin"

    /// `openURL`, `defaults`, and `recordingSupported` are injectable seams so
    /// tests neither drive `NSWorkspace`, read the real preference, nor depend
    /// on the host's macOS version. `forceRecord` (the notification's
    /// "Join + Record" action) starts a recording regardless of the
    /// auto-record setting — the OS-support gate and the single-capture
    /// guard still apply.
    static func join(
        event: CalendarEvent,
        center: MeetingRecorderCenter,
        forceRecord: Bool = false,
        defaults: UserDefaults = .standard,
        recordingSupported: Bool = SystemAudioRecorder.isSupported,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async {
        guard let url = event.conferenceLink else { return }
        guard openURL(url) else {
            // LaunchServices refused (broken default-browser registration, …):
            // the user never joined, so don't start recording a meeting they
            // are not in — but leave a trace for diagnosis.
            print("[JoinMeeting] failed to open \(url.absoluteString)")
            return
        }

        // `recordingSupported` mirrors the manual Record button's
        // `SystemAudioRecorder.isSupported` gate (macOS 14.4+): on 14.0–14.3
        // Join opens the link only, instead of dropping the Center into a
        // failure banner for a recording the user never requested.
        let autoRecord = defaults.object(forKey: autoRecordKey) as? Bool ?? true
        guard forceRecord || autoRecord, recordingSupported, !center.isCapturing else { return }
        // A start failure surfaces through the Center's own error path
        // (RecordingIndicatorView) — the link has already opened above.
        await center.startRecording(eventID: event.id, title: event.title, config: .fromDefaults(defaults))
    }
}
