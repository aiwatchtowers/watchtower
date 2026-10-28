import SwiftUI
import WatchtowerCore

/// Record/Stop control for a calendar event, or ad-hoc capture when
/// `eventID`/`title` are nil. Shared between the Meetings list header
/// (ad-hoc, always visible) and `MeetingDetailView`'s event header (gated by
/// `MeetingDetailView.showsRecordButton`). Shows "Stop" only while THIS
/// target is the one being recorded; disabled when another recording is
/// capturing or system-audio capture is unsupported. A previous recording
/// still being transcribed does NOT disable it — post-processing is queued,
/// not exclusive. Record's menu holds **Record Privately** (MEETPRIV); the
/// plain click follows Settings → Meetings' private default.
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
        Group {
            if isRecordingThis {
                // No CLI-runner guard here: stopping capture must never
                // depend on the watchtower binary resolving — the Center
                // fails visibly at the save step instead, with the audio kept.
                Button {
                    Task { await center.stopAndProcess(config: .fromDefaults()) }
                } label: {
                    Label("Stop", systemImage: "stop.circle").font(.caption)
                }
                .buttonStyle(.kitDestructive)
            } else {
                // The plain click follows the Settings default
                // (`transcription.privateByDefault`); the menu forces private.
                Menu {
                    Button {
                        start(isPrivate: true)
                    } label: {
                        Label("Record Privately", systemImage: "lock.fill")
                    }
                    .help("Saved without a recap and never sent to AI")
                } label: {
                    Label("Record", systemImage: "record.circle").font(.caption)
                } primaryAction: {
                    start(isPrivate: false)
                }
                .menuStyle(.button)
                .buttonStyle(.kitSecondary)
                .fixedSize()
            }
        }
        .controlSize(.small)
        .disabled((center.isCapturing && !isRecordingThis) || !SystemAudioRecorder.isSupported)
        .help(SystemAudioRecorder.isSupported ? firstRecordingHint : "Recording requires macOS 14.4+")
    }

    /// `isPrivate` false still records privately when the Settings default is on.
    private func start(isPrivate: Bool) {
        let center = appState.meetingRecorderCenter
        Task { await center.startRecording(eventID: eventID, title: title, isPrivate: isPrivate, config: .fromDefaults()) }
    }

    /// Said before the first recording, while the model is not known to be
    /// on disk (#744; an install from before it has no record yet): that
    /// recording downloads it, once.
    private var firstRecordingHint: String {
        guard let key = appState.meetingModelKey, !appState.transcriptionModelProvisioner.isDownloaded(key) else {
            return ""
        }
        let size = TranscriptionModelProvisioner.describe(key).sizeBytes.map { " (about \(ModelDownloadText.size($0)))" } ?? ""
        return "Unless it is on this Mac already, the first recording downloads the transcription model\(size) — once."
    }
}
