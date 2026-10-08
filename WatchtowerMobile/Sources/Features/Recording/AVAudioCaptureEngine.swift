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
@MainActor
final class AVAudioCaptureEngine: AudioCaptureEngine {
    var onFailure: (@MainActor (String) -> Void)?

    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    private var audioEngine: AVAudioEngine?
    private var writer: AVAssetWriter?
    private var sink: TapSink?
    private var resetObserver: (any NSObjectProtocol)?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AVAudioCaptureEngine")

    private enum CaptureError: LocalizedError {
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case let .writerFailed(reason): "The recording file could not be written: \(reason)"
            }
        }
    }

    init() {
        // A media-services reset kills the engine and the writer under us:
        // the capture ends there, and the controller saves what was written.
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.writer != nil else { return }
                self.onFailure?("Audio services restarted, so the recording stopped here.")
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
        // into the same file.
        try AVAudioSession.sharedInstance().setActive(true)
        try audioEngine?.start()
        sink?.setPaused(false)
    }

    func finish() async {
        sink?.setPaused(true)
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        sink = nil
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

    func append(_ buffer: AVAudioPCMBuffer) {
        let (frames, skip) = state.withLock { ($0.frames, $0.paused || $0.failed) }
        guard !skip, buffer.frameLength > 0 else { return }
        let level = Self.level(of: buffer)
        // A writer that cannot take more right now drops this buffer rather
        // than blocking the audio thread.
        guard input.isReadyForMoreMediaData else { return }
        let pts = CMTime(value: frames, timescale: CMTimeScale(sampleRate.rounded()))
        guard let sample = Self.sampleBuffer(buffer, pts: pts), input.append(sample) else {
            let firstFailure = state.withLock { current -> Bool in
                defer { current.failed = true }
                return !current.failed
            }
            if firstFailure {
                report("The recording could not be encoded, so it stopped here.")
            }
            return
        }
        state.withLock {
            $0.frames += Int64(buffer.frameLength)
            $0.level = level
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
