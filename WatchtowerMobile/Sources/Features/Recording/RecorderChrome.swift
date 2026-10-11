import Foundation

/// What the capture screen shows for a phase (design pass spec §3 bug 9):
/// the mark top right, the left control (Pause, or Resume while paused) and
/// whether Stop and Mark moment work. `.idle` is the screen while `start()`
/// awaits microphone permission, so it says Starting…, not PAUSED.
struct RecorderChrome: Equatable {
    enum Mark: Equatable {
        case starting, recording, paused, saving
    }

    let mark: Mark
    let markText: String
    let markTone: PhoneTone
    let leftTitle: String
    let leftSystemImage: String
    let isLeftEnabled: Bool
    /// Stop and Mark moment.
    let areCaptureControlsEnabled: Bool

    /// The left control resumes rather than pauses.
    var resumes: Bool { mark == .paused }
}

extension RecorderChrome {
    /// nil outside the capture phases (saved, too short, denied, failed).
    init?(phase: PhoneRecorderController.Phase) {
        switch phase {
        case .idle:
            self.init(mark: .starting, markText: "Starting…", markTone: .secondary, leftTitle: "Pause",
                      leftSystemImage: "pause.fill", isLeftEnabled: false, areCaptureControlsEnabled: false)
        case .recording:
            self.init(mark: .recording, markText: "REC", markTone: .red, leftTitle: "Pause",
                      leftSystemImage: "pause.fill", isLeftEnabled: true, areCaptureControlsEnabled: true)
        case .paused:
            self.init(mark: .paused, markText: "PAUSED", markTone: .secondary, leftTitle: "Resume",
                      leftSystemImage: "play.fill", isLeftEnabled: true, areCaptureControlsEnabled: true)
        case .saving:
            self.init(mark: .saving, markText: "Saving…", markTone: .secondary, leftTitle: "Pause",
                      leftSystemImage: "pause.fill", isLeftEnabled: false, areCaptureControlsEnabled: false)
        case .saved, .tooShort, .denied, .failed:
            return nil
        }
    }
}
