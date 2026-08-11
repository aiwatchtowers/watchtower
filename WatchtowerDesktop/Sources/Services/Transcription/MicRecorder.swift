import AVFoundation
import Foundation

/// Mic-only live capture for dictation. Unlike `AudioRecording` it writes no
/// file — samples exist only in the stream (the caller buffers them).
protocol MicRecording: AnyObject {
    /// Requests mic permission on first use; throws on denial or engine failure.
    func start() async throws
    func stop()
    /// Live 16 kHz mono Float32 samples; finishes when `stop()` is called.
    var samples: AsyncStream<[Float]> { get }
    /// First capture error latched mid-stream (e.g. every buffer conversion
    /// failing). Read after the stream ends: an empty capture with a non-nil
    /// error is a broken mic path, not silence.
    var lastError: Error? { get }
}

enum MicRecorderError: LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .engineStartFailed(let reason):
            return "Could not start microphone capture: \(reason)"
        }
    }
}

/// `AVAudioEngine`-based mic capture, downsampled to 16 kHz mono for
/// dictation. No file is ever written; the tap converts each buffer through
/// an `AVAudioConverter` (the `SystemAudioRecorder.appendDownsampled`
/// pattern, `SystemAudioRecorder.swift:326-363`) and yields straight into the
/// stream.
final class MicRecorder: MicRecording {
    private static let outputSampleRate: Double = 16_000

    private let requestAccess: () async -> Bool
    private let engine = AVAudioEngine()
    /// Owns `converter` and every buffer conversion — the tap callback runs on
    /// AVAudioEngine's internal audio thread, so without a single serial queue
    /// its read of `converter` in `appendDownsampled` could race `stop()`'s
    /// write. Mirrors `SystemAudioRecorder.writeQueue`
    /// (`SystemAudioRecorder.swift:80-82, 140-141`).
    private let convertQueue = DispatchQueue(label: "com.watchtower.dictation.mic-recorder")
    private var converter: AVAudioConverter?
    /// First conversion error, latched on `convertQueue` (the
    /// `SystemAudioRecorder.firstWriteError` pattern). `stop()`'s barrier
    /// orders the write before any post-stop read of `lastError`.
    private var firstConversionError: Error?

    private var continuation: AsyncStream<[Float]>.Continuation!
    let samples: AsyncStream<[Float]>

    init(requestAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.requestAccess = requestAccess
        var c: AsyncStream<[Float]>.Continuation!
        samples = AsyncStream { c = $0 }
        continuation = c
    }

    var lastError: Error? { convertQueue.sync { firstConversionError } }

    func start() async throws {
        // The tap is already installed — a second start would stack a second
        // tap on the input node (the SystemAudioRecorder `impl != nil`
        // precedent).
        guard convertQueue.sync(execute: { converter == nil }) else {
            throw MicRecorderError.engineStartFailed("already started")
        }
        guard await requestAccess() else { throw MicRecorderError.microphonePermissionDenied }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.outputSampleRate, channels: 1, interleaved: false
        ), let downConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicRecorderError.engineStartFailed("creating 16 kHz converter")
        }
        convertQueue.sync { converter = downConverter }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertQueue.async { self?.appendDownsampled(buffer) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            convertQueue.sync { converter = nil }
            throw MicRecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Barrier on convertQueue so an in-flight appendDownsampled (already
        // dispatched by the tap before removeTap took effect) finishes before
        // converter is torn down — the SystemAudioRecorder.stop() precedent.
        convertQueue.sync { converter = nil }
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }

    /// Converts one tap buffer to 16 kHz mono and yields it into the stream.
    /// Runs on `convertQueue` (dispatched there by the tap callback), the
    /// same queue `stop()` barriers on to tear down `converter`. Mirrors
    /// `SystemAudioRecorder.appendDownsampled`: the `consumed` one-shot input
    /// block hands the converter exactly one buffer, and a
    /// `frameLength > 0` guard drops empty conversion results.
    private func appendDownsampled(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.outputSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            if firstConversionError == nil {
                firstConversionError = conversionError
                NSLog("MicRecorder: audio conversion failed: %@", conversionError.localizedDescription)
            }
            return
        }
        guard outBuffer.frameLength > 0, let data = outBuffer.floatChannelData?[0] else {
            return
        }
        let n = Int(outBuffer.frameLength)
        continuation.yield(Array(UnsafeBufferPointer(start: data, count: n)))
    }
}
