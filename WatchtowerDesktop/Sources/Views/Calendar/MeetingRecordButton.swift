import SwiftUI

/// Record/Stop control for a calendar event, or ad-hoc capture when
/// `eventID`/`title` are nil. Shared between the Meetings list header
/// (ad-hoc, always visible) and `MeetingDetailView`'s event header (gated by
/// `MeetingDetailView.showsRecordButton`). Shows "Stop" only while THIS
/// target is the one being recorded; disabled when another recording is
/// capturing or system-audio capture is unsupported. A previous recording
/// still being transcribed does NOT disable it — post-processing is queued,
/// not exclusive.
struct MeetingRecordButton: View {
    let eventID: String?
    let title: String?

    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.meetingRecorderCenter
        let isRecordingThis: Bool = {
            if case .recording = center.phase { return center.currentEventID == eventID }
            return false
        }()
        Button {
            if isRecordingThis {
                // No CLI-runner guard here: stopping capture must never
                // depend on the watchtower binary resolving — the Center
                // fails visibly at the save step instead, with the audio kept.
                Task { await center.stopAndProcess(config: .fromDefaults()) }
            } else {
                Task { await center.startRecording(eventID: eventID, title: title, config: .fromDefaults()) }
            }
        } label: {
            Label(isRecordingThis ? "Stop" : "Record",
                  systemImage: isRecordingThis ? "stop.circle" : "record.circle")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isRecordingThis ? .red : nil)
        .disabled((center.isCapturing && !isRecordingThis) || !SystemAudioRecorder.isSupported)
        .help(SystemAudioRecorder.isSupported ? "" : "Recording requires macOS 14.4+")
    }
}
