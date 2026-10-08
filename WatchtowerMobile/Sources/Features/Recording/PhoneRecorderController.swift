import AVFoundation
import Foundation
import Observation
import os
import WatchtowerSync

/// The audio seam under the recorder: `AVAudioCaptureEngine` on a device,
/// a fake in tests (no audio is ever recorded there).
@MainActor
protocol AudioCaptureEngine: AnyObject {
    func requestPermission() async -> Bool
    /// Activates the audio session and starts writing `url`.
    func begin(url: URL) throws
    func pause()
    /// Continues writing the same file after a pause or an interruption.
    func resume() throws
    /// Stops and finalises the file, then releases the audio session.
    func finish()
    /// The current input level, 0...1, for the waveform.
    func level() -> Float
}

/// The calendar event a "Record this meeting" capture belongs to. The
/// Calendar (Task 7) builds it from a `calendar_event` record.
struct MeetingEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date

    /// "14:00–14:45" in the phone's time zone.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(clock.string(from: start))–\(clock.string(from: end))"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// What a recording is tied to: a calendar event, or nothing (a voice note).
enum RecordingContext: Equatable {
    case meeting(MeetingEvent)
    case voiceNote
}

/// One recording finalised on the phone and handed to the uploader.
struct SavedRecording: Equatable {
    let id: String
    let durationSec: Int
}

/// Phone audio capture (spec §13 C2): AAC 64 kbps mono `.m4a`, recorded
/// locally first, then handed to the Kit's `RecordingUploader`, which
/// relays it to the Mac through iCloud. Owned by `AppEnvironment` for the
/// app's lifetime, so a recording survives any navigation and the
/// Minimize link.
///
/// Lifecycle facts:
/// - Files land in Application Support/phone-recordings/<uuid>.m4a and
///   stay until the Mac acknowledges receipt.
/// - The `audio` background mode keeps an active capture going with the
///   screen locked. The recorder never touches the fetch loop, which
///   pauses in the background as usual.
/// - An `AVAudioSession` interruption (a call, Siri) pauses the capture;
///   its end resumes into the SAME file, and the timer excludes the gap.
/// - Time is read only through `now`, and the recorded length is the sum
///   of the recording spans, so pauses and interruptions are not audio.
@MainActor
@Observable
final class PhoneRecorderController {
    enum PauseReason: Equatable {
        case user
        case interruption
    }

    enum Phase: Equatable {
        case idle
        case recording
        case paused(PauseReason)
        case saved(SavedRecording)
        /// Stopped under a second of audio: discarded, never uploaded.
        case tooShort
        /// Microphone access denied.
        case denied
        case failed(String)
    }

    /// The length cap and its notice (spec §3): auto-stop at 3 h, notice
    /// 5 minutes before.
    static let maximumDuration: TimeInterval = 3 * 3_600
    static let capNoticeLead: TimeInterval = 5 * 60
    static let capNoticeText = "Recording stops in 5 minutes (3-hour limit)."
    /// Waveform bars kept on screen.
    static let waveformBars = 48

    private(set) var phase: Phase = .idle
    private(set) var context: RecordingContext = .voiceNote
    /// The event the segmented control offers; nil for a free voice note.
    private(set) var offeredEvent: MeetingEvent?
    /// Whether the full-screen recorder is up (false after Minimize).
    private(set) var isPresented = false
    /// Recorded audio so far, in seconds (pauses excluded).
    private(set) var elapsed: TimeInterval = 0
    /// Mark-moment offsets, in whole seconds of recorded audio.
    private(set) var marks: [Int] = []
    /// Recent input levels, oldest first, for the waveform.
    private(set) var levels: [Float] = []
    private(set) var capNotice: String?

    /// Raised once when the cap notice appears; the app posts a local
    /// notification, since the screen is usually locked by then.
    @ObservationIgnored var onCapNotice: @MainActor () -> Void = {}

    @ObservationIgnored private let uploader: RecordingUploader
    @ObservationIgnored private let engine: any AudioCaptureEngine
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let tickInterval: Duration?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var startedAt: Date?
    /// Audio recorded before the current span.
    @ObservationIgnored private var accumulated: TimeInterval = 0
    /// When the current recording span began; nil while paused.
    @ObservationIgnored private var spanStart: Date?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Kept for the controller's lifetime (the environment owns it for the
    /// app's), so it is never removed.
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "PhoneRecorder")

    /// - `tickInterval`: how often the timer, waveform and cap advance;
    ///   nil in tests, which call `tick()` themselves.
    init(
        uploader: RecordingUploader,
        engine: any AudioCaptureEngine,
        directory: URL,
        notificationCenter: NotificationCenter = .default,
        now: @escaping @MainActor () -> Date = { Date() },
        tickInterval: Duration? = .milliseconds(100)
    ) {
        self.uploader = uploader
        self.engine = engine
        self.directory = directory
        self.now = now
        self.tickInterval = tickInterval
        // Registered for the controller's lifetime: a call while recording
        // must pause the capture even with no view on screen.
        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let event = Interruption(note.userInfo)
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    /// Where captures wait until the Mac acknowledges receipt.
    nonisolated static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("phone-recordings", isDirectory: true)
    }

    // MARK: - Derived state

    /// A capture is running or paused (not yet stopped).
    var isCapturing: Bool {
        switch phase {
        case .recording, .paused: true
        default: false
        }
    }

    var savedRecording: SavedRecording? {
        if case let .saved(saved) = phase { return saved }
        return nil
    }

    /// The segmented control's options: the event's title and "No meeting";
    /// empty for a free voice note (nothing to switch to).
    var contextOptions: [String] {
        offeredEvent.map { [$0.title, "No meeting"] } ?? []
    }

    /// "Design sync · 14:00–14:45" or "Voice note · not tied to an event".
    var contextLabel: String {
        switch context {
        case let .meeting(event):
            "\(event.title) · \(MeetingEvent.timeRange(event.start, event.end))"
        case .voiceNote:
            "Voice note · not tied to an event"
        }
    }

    var timerText: String {
        Self.clockText(Int(elapsed))
    }

    var statusLine: String {
        switch phase {
        case .recording:
            "Keeps going with the screen locked. \(marks.count) \(marks.count == 1 ? "moment" : "moments") marked."
        case .paused(.interruption): "Paused — call in progress"
        case .paused(.user): "Paused"
        case let .saved(saved): "Saved · \(Self.clockText(saved.durationSec))"
        case .tooShort: "Too short to save"
        case .denied: "Microphone access is off. Turn it on in Settings to record."
        case let .failed(message): message
        case .idle: ""
        }
    }

    /// "mm:ss", or "h:mm:ss" from an hour on.
    static func clockText(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - Entry points

    /// "Record this meeting" (the Calendar's entry): opens the recorder and
    /// starts a capture tied to `event`. A capture already running is shown
    /// instead and keeps its own context.
    func recordMeeting(_ event: MeetingEvent) async {
        await open(offering: event)
    }

    /// The free voice-note entry: a capture tied to no event.
    func recordVoiceNote() async {
        await open(offering: nil)
    }

    private func open(offering event: MeetingEvent?) async {
        isPresented = true
        guard !isCapturing else { return }
        offeredEvent = event
        context = event.map(RecordingContext.meeting) ?? .voiceNote
        await start()
    }

    /// The segmented control: the offered event, or "No meeting".
    func selectMeeting(_ tied: Bool) {
        guard let offeredEvent else { return }
        context = tied ? .meeting(offeredEvent) : .voiceNote
    }

    /// The Minimize link: the capture goes on under the tabs.
    func minimize() {
        isPresented = false
    }

    /// The REC bar under the tabs brings the recorder back.
    func reopen() {
        isPresented = true
    }

    /// Closes the finished screen ("See recordings", or a stop that saved
    /// nothing) and returns to idle.
    func close() {
        guard !isCapturing else { return }
        isPresented = false
        phase = .idle
    }

    // MARK: - Capture

    private func start() async {
        reset()
        guard await engine.requestPermission() else {
            phase = .denied
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
            try engine.begin(url: url)
            fileURL = url
            let start = now()
            startedAt = start
            spanStart = start
            phase = .recording
            startTicker()
        } catch {
            Self.logger.error("recording start failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func reset() {
        fileURL = nil
        startedAt = nil
        spanStart = nil
        accumulated = 0
        elapsed = 0
        marks = []
        levels = []
        capNotice = nil
    }

    func pause() {
        guard phase == .recording else { return }
        closeSpan()
        engine.pause()
        phase = .paused(.user)
    }

    func resume() {
        guard case .paused = phase else { return }
        do {
            try engine.resume()
            spanStart = now()
            phase = .recording
        } catch {
            Self.logger.error("recording resume failed: \(error.localizedDescription, privacy: .public)")
            phase = .paused(.user)
        }
    }

    func markMoment() {
        guard isCapturing else { return }
        refreshElapsed()
        marks.append(Int(elapsed))
    }

    /// Stops and finalises the capture: the file is registered with the
    /// uploader (which discards a capture under a second) and the upload
    /// pass runs at once. Safe to call when nothing is capturing.
    func stop() async {
        guard isCapturing, let fileURL, let startedAt else { return }
        closeSpan()
        let duration = min(accumulated, Self.maximumDuration)
        engine.finish()
        tickTask?.cancel()
        tickTask = nil
        self.fileURL = nil
        self.startedAt = nil
        elapsed = duration

        let eventID: String?
        let title: String
        switch context {
        case let .meeting(event):
            eventID = event.id
            title = event.title
        case .voiceNote:
            eventID = nil
            title = "Voice note — \(Self.titleStamp.string(from: startedAt))"
        }
        do {
            let registered = try await uploader.register(
                fileURL: fileURL,
                startedAt: startedAt,
                endedAt: now(),
                activeDuration: duration,
                titleHint: title,
                eventID: eventID,
                marks: marks
            )
            guard let registered else {
                phase = .tooShort
                return
            }
            phase = .saved(SavedRecording(id: registered.id, durationSec: registered.durationSec))
        } catch {
            Self.logger.error("recording save failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed("Could not save the recording: \(error.localizedDescription)")
            return
        }
        await uploadPending()
    }

    /// Retry on a failed upload: back to waiting, then an upload pass.
    func retry(id: String) async {
        do {
            try await uploader.retryFailed(id: id)
        } catch {
            Self.logger.error("recording retry failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hands every waiting recording to the transport; the file stays on
    /// disk, so a failed pass is retried at the next launch.
    func uploadPending() async {
        do {
            try await uploader.uploadPending()
        } catch {
            Self.logger.warning("recording upload pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Ticks

    /// Advances the timer and waveform, raises the cap notice and stops at
    /// the cap. Driven by the ticker on a device and by the tests directly.
    func tick() async {
        guard isCapturing else { return }
        refreshElapsed()
        if phase == .recording {
            levels.append(max(0, min(1, engine.level())))
            if levels.count > Self.waveformBars {
                levels.removeFirst(levels.count - Self.waveformBars)
            }
        }
        if capNotice == nil, elapsed >= Self.maximumDuration - Self.capNoticeLead {
            capNotice = Self.capNoticeText
            onCapNotice()
        }
        if elapsed >= Self.maximumDuration {
            await stop()
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        guard let tickInterval else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self else { return }
                await self.tick()
            }
        }
    }

    private func refreshElapsed() {
        elapsed = accumulated + (spanStart.map { now().timeIntervalSince($0) } ?? 0)
    }

    /// Folds the running span into `accumulated` (pause, interruption,
    /// stop).
    private func closeSpan() {
        if let spanStart {
            accumulated += now().timeIntervalSince(spanStart)
        }
        spanStart = nil
        elapsed = accumulated
    }

    // MARK: - Interruptions

    /// An `AVAudioSession` interruption, parsed off the notification.
    private enum Interruption {
        case began
        case ended(shouldResume: Bool)
        case unknown

        init(_ info: [AnyHashable: Any]?) {
            guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else {
                self = .unknown
                return
            }
            switch type {
            case .began:
                self = .began
            case .ended:
                let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                self = .ended(shouldResume: options.contains(.shouldResume))
            @unknown default:
                self = .unknown
            }
        }
    }

    private func handle(_ interruption: Interruption) {
        switch interruption {
        case .began:
            // The system already paused the recorder; only a running
            // capture changes state (an owner pause stays an owner pause).
            guard phase == .recording else { return }
            closeSpan()
            engine.pause()
            phase = .paused(.interruption)
        case let .ended(shouldResume):
            guard phase == .paused(.interruption) else { return }
            if shouldResume {
                resume()
            } else {
                phase = .paused(.user)
            }
        case .unknown:
            break
        }
    }

    private static let titleStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()
}
