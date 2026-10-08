import AVFoundation
import Foundation

/// The device's `AudioCaptureEngine`: an `AVAudioRecorder` writing AAC
/// 64 kbps mono `.m4a` (`sample_format = "aac-64k-mono"`, spec §3) under
/// a `.record` audio session. The `audio` background mode keeps it
/// recording with the screen locked. A thin shell: every decision lives
/// in `PhoneRecorderController`.
@MainActor
final class AVAudioCaptureEngine: AudioCaptureEngine {
    private var recorder: AVAudioRecorder?

    private enum CaptureError: LocalizedError {
        case startFailed
        case resumeFailed

        var errorDescription: String? {
            switch self {
            case .startFailed: "The microphone did not start."
            case .resumeFailed: "The microphone did not resume."
            }
        }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func begin(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.startFailed
        }
        self.recorder = recorder
    }

    func pause() {
        recorder?.pause()
    }

    func resume() throws {
        // An interruption deactivated the session; recording again appends
        // to the same file.
        try AVAudioSession.sharedInstance().setActive(true)
        guard recorder?.record() == true else { throw CaptureError.resumeFailed }
    }

    func finish() {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Average power mapped from -50...0 dB to 0...1.
    func level() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return max(0, min(1, (decibels + 50) / 50))
    }
}
