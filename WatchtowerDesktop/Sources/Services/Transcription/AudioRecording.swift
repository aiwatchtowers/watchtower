import Foundation

/// Result of a finished meeting recording.
struct RecordingResult: Equatable {
    let audioURL: URL
    let durationSec: Int
}

/// One ~100 ms window of live capture levels for the recording UI's meters.
/// Both values are RMS over the RAW pre-gain samples — the `rec_X.activity`
/// sidecar's convention — so the meter reflects what the mic actually picks
/// up, not what `MicAGC` makes of it.
struct CaptureLevels: Equatable, Sendable {
    let mic: Float     // raw pre-AGC mic RMS over the last ~100 ms
    let system: Float  // system-channel RMS over the same window
}

/// Abstraction over the audio capture stack so MeetingRecorderCenter is
/// testable without CoreAudio or TCC permissions.
protocol AudioRecording: AnyObject {
    /// Begins capturing mic + system audio into `url` (16 kHz mono AAC in a
    /// crash-tolerant .caf container). Throws immediately on permission denial
    /// or unsupported OS.
    func start(to url: URL) async throws
    /// Closes the file; always safe to call once after a successful start.
    /// Throws `.writeFailed` when writing broke mid-recording — the truncated
    /// file is kept on disk, but it must not be reported as a clean success.
    func stop() async throws -> RecordingResult
    /// Live 16 kHz mono Float32 samples delivered as they are captured, for
    /// in-progress transcription. Finishes when `stop()` is called. Consuming it
    /// is optional — a recording works identically whether or not anyone reads it.
    var liveSamples: AsyncStream<[Float]> { get }
    /// Throttled (~10 Hz) live level pairs; finishes on stop(). Optional to consume.
    var liveLevels: AsyncStream<CaptureLevels> { get }
}

enum AudioRecordingError: LocalizedError {
    case unsupportedOS
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case deviceSetupFailed(String)
    case writeFailed(String)

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
        case .writeFailed(let message):
            return "Recording was cut short by a write error: \(message). The partial audio was kept."
        }
    }
}
