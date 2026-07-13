import Foundation

/// Result of a finished meeting recording.
struct RecordingResult: Equatable {
    let audioURL: URL
    let durationSec: Int
}

/// Abstraction over the audio capture stack so MeetingRecorderCenter is
/// testable without CoreAudio or TCC permissions.
protocol AudioRecording: AnyObject {
    /// Begins capturing mic + system audio into `url` (16 kHz mono AAC .m4a).
    /// Throws immediately on permission denial or unsupported OS.
    func start(to url: URL) async throws
    /// Finalizes the file; always safe to call once after a successful start.
    func stop() async throws -> RecordingResult
}

enum AudioRecordingError: LocalizedError {
    case unsupportedOS
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Meeting recording requires macOS 14.4 or newer."
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .systemAudioPermissionDenied:
            return "System audio recording was denied. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .deviceSetupFailed(let message):
            return "Audio device setup failed: \(message)"
        }
    }
}
