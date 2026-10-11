import AVFoundation
import CoreMedia
import Foundation
import os

/// The device's `AudioCaptureEngine`: the microphone through an
/// `AVAudioEngine` input tap, encoded by an `AVAssetWriter` into AAC
/// 44.1 kHz mono 64 kbps `.m4a` (`sample_format = "aac-64k-mono"`,
/// spec §3). The writer resamples and downmixes the hardware format.
///
/// The file is a FRAGMENTED MP4 (`movieFragmentInterval` 10 s): a capture
/// cut short by a kill, jetsam or crash stays playable up to its last
/// fragment, and the next launch finalizes it from the file
/// (`RecordingUploader.recoverInterruptedCaptures`). The Mac's
/// `AVAudioFile` decode reads a finished and a killed fragmented file
/// alike (checked on macOS with the same writer settings).
///
/// Presentation times count written frames, so a pause or an interruption
/// leaves no gap in the file. The `audio` background mode keeps the
/// capture running with the screen locked.
///
/// A route or configuration change (AirPods, a wired headset, CarPlay)
/// stops an `AVAudioEngine` and usually changes the input format. For the
/// POC the capture ends there with a notice and what was written is saved
/// (`CaptureEndWatch`): the tap is never left silent while the timer runs,
/// and never restarted at a mismatched format.
@MainActor
final class AVAudioCaptureEngine: AudioCaptureEngine {
    var onFailure: (@MainActor (String) -> Void)?

    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    private var audioEngine: AVAudioEngine?
    private var writer: AVAssetWriter?
    private var sink: TapSink?
    /// The format the tap was installed with; a resume at any other input
    /// format ends the capture instead.
    private var tapFormat: AVAudioFormat?
    private var watch: CaptureEndWatch?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AVAudioCaptureEngine")

    private enum CaptureError: LocalizedError {
        case writerFailed(String)
        case microphoneChanged

        var errorDescription: String? {
            switch self {
            case let .writerFailed(reason): "The recording file could not be written: \(reason)"
            case .microphoneChanged: CaptureEndWatch.microphoneChangedMessage
            }
        }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func begin(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            writer.movieFragmentInterval = Self.fragmentInterval
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else {
                throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
            }
            writer.startSession(atSourceTime: .zero)

            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            let sink = TapSink(input: input, sampleRate: format.sampleRate) { [weak self] message in
                Task { @MainActor in self?.onFailure?(message) }
            }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
                sink.append(buffer)
            }
            try engine.start()
            self.writer = writer
            self.audioEngine = engine
            self.sink = sink
            self.tapFormat = format
            watch = CaptureEndWatch(engine: engine) { [weak self] message in
                self?.onFailure?(message)
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func pause() {
        sink?.setPaused(true)
        audioEngine?.pause()
    }

    func resume() throws {
        // An interruption deactivated the session; the writer keeps going
        // into the same file, but only at the format the tap was made for
        // (starting a tap at a stale format raises an uncatchable exception).
        try AVAudioSession.sharedInstance().setActive(true)
        guard let audioEngine, let tapFormat else { return }
        let current = audioEngine.inputNode.outputFormat(forBus: 0)
        guard current.sampleRate == tapFormat.sampleRate, current.channelCount == tapFormat.channelCount else {
            throw CaptureError.microphoneChanged
        }
        try audioEngine.start()
        sink?.setPaused(false)
    }

    func finish() async {
        watch?.cancel()
        watch = nil
        // After this no buffer is appended, even one already in the tap.
        sink?.finish()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        sink = nil
        tapFormat = nil
        if let writer {
            self.writer = nil
            if writer.status == .writing {
                writer.inputs.forEach { $0.markAsFinished() }
                await writer.finishWriting()
            }
            if writer.status == .failed {
                Self.logger.error("writer failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func level() -> Float {
        sink?.level ?? 0
    }

    func recordedDuration(of url: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds > 0 ? seconds : nil
    }
}

/// The tap's side of the capture: runs on the audio thread, appends each
/// buffer to the writer input, and keeps the level for the waveform.
private final class TapSink: @unchecked Sendable {
    private struct State {
        var frames: Int64 = 0
        var paused = false
        var level: Float = 0
        var failed = false
        /// Set by `finish()`: no append after it, ever.
        var finished = false
    }

    private let input: AVAssetWriterInput
    private let sampleRate: Double
    private let report: @Sendable (String) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(input: AVAssetWriterInput, sampleRate: Double, report: @escaping @Sendable (String) -> Void) {
        self.input = input
        self.sampleRate = sampleRate
        self.report = report
    }

    var level: Float {
        state.withLock { $0.level }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { $0.paused = paused }
    }

    /// Waits out an append in progress, then refuses every later one: the
    /// writer may be finished right after this returns.
    func finish() {
        state.withLock { $0.finished = true }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let level = Self.level(of: buffer)
        // The check and the append run under one lock, so `finish()` can
        // never slip between them and an append never follows
        // `markAsFinished`. A writer that cannot take more right now drops
        // this buffer rather than blocking the audio thread.
        let failedNow = state.withLockUnchecked { current -> Bool in
            guard !current.paused, !current.failed, !current.finished, input.isReadyForMoreMediaData else { return false }
            let pts = CMTime(value: current.frames, timescale: CMTimeScale(sampleRate.rounded()))
            guard let sample = Self.sampleBuffer(buffer, pts: pts), input.append(sample) else {
                current.failed = true
                return true
            }
            current.frames += Int64(buffer.frameLength)
            current.level = level
            return false
        }
        if failedNow {
            report("Recording stopped: the audio could not be encoded.")
        }
    }

    /// RMS of the first channel mapped from -50...0 dB to 0...1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(max(count, 1))).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (decibels + 50) / 50))
    }

    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: buffer.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: pts.timescale),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sample
    }
}

/// Ends a capture when the audio stack changes under it: an
/// `AVAudioEngineConfigurationChange` from this capture's engine (a route
/// change, such as AirPods connecting) or a media-services reset. The
/// owner sees the notice; the controller saves what was written.
@MainActor
final class CaptureEndWatch {
    nonisolated static let microphoneChangedMessage = "Recording stopped: the microphone changed."
    nonisolated static let servicesResetMessage = "Recording stopped: audio services restarted."

    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    init(center: NotificationCenter = .default, engine: AnyObject, onEnd: @escaping @MainActor (String) -> Void) {
        self.center = center
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onEnd(Self.microphoneChangedMessage) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onEnd(Self.servicesResetMessage) }
        })
    }

    /// Stops watching (the capture finished).
    func cancel() {
        observers.forEach(center.removeObserver)
        observers = []
    }
}
