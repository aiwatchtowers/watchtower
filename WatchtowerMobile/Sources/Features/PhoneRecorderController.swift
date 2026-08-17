import AVFoundation
import Foundation
import Observation
import os
import WatchtowerKit

/// Phone audio capture for the Recordings tab (voice-memo style): AAC
/// ~64 kbps mono `.m4a` files, recorded locally first, then handed to
/// `RecordingUploader` for relay to the Mac. Deliberately a THIN
/// AVFoundation shell — every decision that needs tests (upload states,
/// retries, ack-then-delete, degenerate captures) lives in the Kit's
/// `RecordingUploader`.
///
/// Lifecycle facts:
/// - Files land in Application Support/phone-recordings/<uuid>.m4a and
///   survive an app kill; a capture cut short by a kill is an orphan file
///   with no ledger row (never uploaded, reclaimed by `sweepOrphans`).
/// - The `audio` UIBackgroundModes entry keeps an active AVAudioSession
///   recording through lock/background.
/// - An AVAudioSession interruption (phone call) stops and FINALIZES the
///   segment gracefully — the recording is registered and queued for
///   upload, not lost.
@MainActor
@Observable
final class PhoneRecorderController {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        /// Microphone permission denied — the button routes to Settings.
        case denied
    }

    private(set) var state: State = .idle
    /// Last start/stop failure, shown inline under the record button.
    private(set) var lastError: String?

    private let uploader: RecordingUploader
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var interruptionObserver: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "WatchtowerMobile", category: "PhoneRecorder")

    init(uploader: RecordingUploader) {
        self.uploader = uploader
        // Registered for the controller's lifetime: a phone call while
        // recording must finalize the segment even if no view is on screen.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in await self?.stop() }
        }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Where captures live until the hub acknowledges receipt.
    nonisolated static func recordingsDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("phone-recordings", isDirectory: true)
    }

    func toggle() async {
        if isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !isRecording else { return }
        lastError = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let dir = Self.recordingsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            guard recorder.record() else {
                throw RecorderError.startFailed
            }
            self.recorder = recorder
            let now = Date()
            startedAt = now
            state = .recording(startedAt: now)
        } catch {
            lastError = error.localizedDescription
            state = .idle
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Stops and FINALIZES the active capture: the file is registered with
    /// the uploader (which discards degenerate blips) and the upload pass
    /// runs immediately. Safe to call when idle (interruption for a session
    /// we no longer own).
    func stop() async {
        guard let recorder, let startedAt else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.startedAt = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let ended = Date()
        let hint = Self.defaultTitleHint(for: startedAt)
        do {
            let registered = try await uploader.register(
                fileURL: url, startedAt: startedAt, endedAt: ended, titleHint: hint
            )
            guard registered != nil else { return } // degenerate blip, discarded
            _ = try await uploader.uploadPending()
        } catch {
            // The file is on disk; the launch-time uploadPending retries.
            logger.warning("finalize failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// "Phone recording — 17 Aug, 14:03" — a usable default title on both
    /// screens; the desktop keeps it via the `.meta` sidecar.
    private static func defaultTitleHint(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return "Phone recording — \(formatter.string(from: date))"
    }

    private enum RecorderError: LocalizedError {
        case startFailed

        var errorDescription: String? {
            switch self {
            case .startFailed:
                return "Could not start recording."
            }
        }
    }
}
