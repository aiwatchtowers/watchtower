import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures microphone + system audio into a single 16 kHz mono AAC file in a
/// CAF container (crash-tolerant: CAF needs no header finalization, so a file
/// cut off mid-recording stays decodable) without any virtual audio device
/// (no BlackHole): a CoreAudio process tap grabs the system output, and a
/// private aggregate device combines it with the default input so ONE IOProc
/// delivers both streams clock-aligned.
///
/// The class itself is not availability-gated so callers can hold/construct it
/// unconditionally; `start` throws `.unsupportedOS` below macOS 14.4 (the tap
/// API exists from 14.2 but is only stable enough from 14.4).
final class SystemAudioRecorder: AudioRecording {
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    private var impl: AnyObject?
    private var liveContinuation: AsyncStream<[Float]>.Continuation?
    let liveSamples: AsyncStream<[Float]>
    private var levelsContinuation: AsyncStream<CaptureLevels>.Continuation?
    let liveLevels: AsyncStream<CaptureLevels>

    init() {
        var continuation: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { continuation = $0 }
        liveContinuation = continuation
        var levels: AsyncStream<CaptureLevels>.Continuation!
        liveLevels = AsyncStream { levels = $0 }
        levelsContinuation = levels
    }

    func start(to url: URL) async throws {
        guard #available(macOS 14.4, *) else { throw AudioRecordingError.unsupportedOS }
        guard impl == nil else { throw AudioRecordingError.deviceSetupFailed("recording already in progress") }
        let recorder = TapRecorderImpl(liveContinuation: liveContinuation, levelsContinuation: levelsContinuation)
        liveContinuation = nil
        levelsContinuation = nil
        try await recorder.start(to: url)
        impl = recorder
    }

    func stop() async throws -> RecordingResult {
        guard #available(macOS 14.4, *), let recorder = impl as? TapRecorderImpl else {
            throw AudioRecordingError.deviceSetupFailed("stop() called with no active recording")
        }
        impl = nil
        return try recorder.stop()
    }
}

/// Accumulates per-frame raw mic/system samples into ~100 ms RMS pairs for the
/// recording UI's live level meters — the `MicActivityAccumulator` shape, but
/// yielding a `CaptureLevels` value instead of sidecar lines. Pure (no I/O) so
/// it is unit-testable; the recorder drains `flush` once per IO cycle on its
/// write queue. Internal for tests only.
struct LevelAccumulator {
    private var micSquares: Double = 0
    private var sysSquares: Double = 0
    private var count = 0

    mutating func add(mic: Float, sys: Float) {
        micSquares += Double(mic * mic)
        sysSquares += Double(sys * sys)
        count += 1
    }

    /// The RMS pair once ≥ 0.1 s of frames accumulated (then resets), else nil —
    /// which is what throttles the level stream to ~10 Hz regardless of the
    /// device's IO buffer size.
    mutating func flush(sampleRate: Double) -> CaptureLevels? {
        guard Double(count) >= sampleRate * 0.1 else { return nil }
        let levels = CaptureLevels(
            mic: Float((micSquares / Double(count)).squareRoot()),
            system: Float((sysSquares / Double(count)).squareRoot())
        )
        micSquares = 0
        sysSquares = 0
        count = 0
        return levels
    }
}

// MARK: - Implementation (macOS 14.4+)

@available(macOS 14.4, *)
private final class TapRecorderImpl {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var deviceFormat: AVAudioFormat?
    private var fileURL: URL?
    private var framesWritten: Int64 = 0
    /// First converter/allocation/write error, latched on `writeQueue`. Once
    /// set, no further buffers are written and `stop()` throws `.writeFailed`
    /// so a silently truncated recording never reports success. The partial
    /// file up to the error stays on disk.
    private var firstWriteError: Error?
    /// Live sample sink, handed off from the facade at construction; finished
    /// on `stop()`/`deinit` so a downstream `for await` loop ends.
    private let liveContinuation: AsyncStream<[Float]>.Continuation?
    /// Live level sink (same handoff/finish contract as `liveContinuation`).
    private let levelsContinuation: AsyncStream<CaptureLevels>.Continuation?
    /// ~10 Hz live level throttle. Like `activityAccumulator`, touched only
    /// inside the IO block (which CoreAudio schedules on `writeQueue`), and fed
    /// the same RAW pre-gain values — never the AGC-scaled mic term.
    private var levelAccumulator = LevelAccumulator()
    /// Best-effort mic/system RMS sidecar (rec_X.activity) for the diarization
    /// post-pass. Losing it only loses the «Я» speaker label, so every failure
    /// here is ignored and never latched into `firstWriteError`.
    private var activityAccumulator: MicActivityAccumulator?
    private var activityHandle: FileHandle?
    /// Adaptive mic gain, fresh per recording so a gain never leaks from one
    /// recording into the next. nil = the `transcription.micAGC` gate is off,
    /// and the mix line below is then exactly what it was before the AGC.
    private var micAGC: MicAGC?

    /// Serial queue owning file writes and converter state; the realtime IO
    /// block only copies + mixes samples and hops here for everything else.
    private let writeQueue = DispatchQueue(label: "com.watchtower.recorder.write")

    private static let outputSampleRate: Double = 16_000

    init(liveContinuation: AsyncStream<[Float]>.Continuation?,
         levelsContinuation: AsyncStream<CaptureLevels>.Continuation?) {
        self.liveContinuation = liveContinuation
        self.levelsContinuation = levelsContinuation
    }

    func start(to url: URL) async throws {
        // 1. Microphone permission (first call shows the TCC prompt).
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw AudioRecordingError.microphonePermissionDenied }

        // 2. Process tap over all system output (first call shows the
        //    System Audio Recording TCC prompt; denial surfaces as an OSStatus error).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw AudioRecordingError.systemAudioPermissionDenied
        }
        tapID = newTapID

        // 3. Private aggregate device: default input device (mic) + the tap.
        do {
            aggregateID = try Self.createAggregateDevice(tapUUID: tapDescription.uuid)
        } catch {
            teardownTap()
            throw error
        }

        // 4. Output file: 16 kHz mono AAC in a CAF container, fed with float32 PCM.
        do {
            try openOutputFile(url: url)
        } catch {
            teardownDevices()
            throw error
        }
        fileURL = url
        framesWritten = 0

        // Best-effort activity sidecar; a failure to create it never fails
        // start. The accumulator exists only while the handle does — RMS math
        // with no consumer is wasted work, and the empty file would linger.
        let activityURL = MicActivity.url(for: url)
        FileManager.default.createFile(atPath: activityURL.path, contents: nil)
        activityHandle = try? FileHandle(forWritingTo: activityURL)
        if activityHandle != nil {
            activityAccumulator = MicActivityAccumulator(sampleRate: Self.nominalSampleRate(of: aggregateID))
        } else {
            try? FileManager.default.removeItem(at: activityURL)
        }
        micAGC = MicAGC.isEnabled() ? MicAGC() : nil

        // 5. IO proc: mix to mono on the realtime thread, write on writeQueue.
        var newProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, writeQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData)
        }
        guard status == noErr, let procID = newProcID else {
            audioFile = nil
            discardActivitySidecar()
            teardownDevices()
            throw AudioRecordingError.deviceSetupFailed("creating IO proc (OSStatus \(status))")
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            audioFile = nil
            discardActivitySidecar()
            teardownDevices()
            throw AudioRecordingError.deviceSetupFailed("starting device (OSStatus \(status))")
        }
    }

    func stop() throws -> RecordingResult {
        // Teardown order matters: IOProc → aggregate → tap, then finalize the file.
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        teardownDevices()
        // Barrier on the write queue so in-flight buffers land before closing.
        let (frames, url, writeError): (Int64, URL?, Error?) = writeQueue.sync {
            let result = (framesWritten, fileURL, firstWriteError)
            audioFile = nil // deallocating AVAudioFile closes the file
            converter = nil
            closeActivitySidecar()
            return result
        }
        liveContinuation?.finish()
        levelsContinuation?.finish()
        guard let audioURL = url else {
            throw AudioRecordingError.deviceSetupFailed("no file was open")
        }
        if let writeError {
            // The truncated file stays on disk for whatever it still holds,
            // but a cut-short recording must not be reported as a success.
            throw AudioRecordingError.writeFailed(writeError.localizedDescription)
        }
        let duration = Int(Double(frames) / Self.outputSampleRate)
        return RecordingResult(audioURL: audioURL, durationSec: duration)
    }

    deinit {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        teardownDevices()
        liveContinuation?.finish()
        levelsContinuation?.finish()
    }

    // MARK: Capture path

    /// Mixes one IO cycle to mono: buffer 0 is the mic sub-device, the rest is
    /// tap (system) audio. Weights port snoop's record.sh lessons — mic at 0.9
    /// so simultaneous loud speech doesn't slam the ceiling, and a tanh-style
    /// soft clip instead of auto-leveling (which drove the signal INTO clipping).
    /// The mic term is additionally scaled by `MicAGC` — see that file for why
    /// this is not the mix-wide leveling snoop was burned on.
    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else { return }

        func channelAverage(_ buffer: AudioBuffer, frame: Int) -> Float {
            guard let data = buffer.mData else { return 0 }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { return 0 }
            // Bound every read by THIS buffer's own mDataByteSize: an
            // off-contract buffer shorter than buffer 0 reads as silence
            // past its end instead of out of bounds.
            let frameCapacity = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            guard frame < frameCapacity else { return 0 }
            let samples = data.assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            for ch in 0..<channels {
                sum += samples[frame * channels + ch]
            }
            return sum / Float(channels)
        }

        /// Mean of every tap (system) buffer at `frame`; 0 when the mic is the
        /// only buffer in the cycle.
        func systemAverage(frame: Int) -> Float {
            guard buffers.count > 1 else { return 0 }
            var acc: Float = 0
            for i in 1..<buffers.count {
                acc += channelAverage(buffers[i], frame: frame)
            }
            return acc / Float(buffers.count - 1)
        }

        let firstBuffer = buffers[0]
        let firstChannels = max(1, Int(firstBuffer.mNumberChannels))
        let frameCount = Int(firstBuffer.mDataByteSize) / (firstChannels * MemoryLayout<Float>.size)
        // An empty IO cycle is normal (no samples this callback) and must not
        // latch an error; drop it. `deviceFormat` is set by openOutputFile()
        // before start() arms the IOProc, so it is never nil while this block
        // runs — treating a nil here as a hard error would be dead code, so it
        // shares the silent early-out.
        guard frameCount > 0, let format = deviceFormat else { return }
        // A failed mixed-buffer allocation is a real, persistent failure (memory
        // pressure): latch it like appendDownsampled does so a run that can no
        // longer mix surfaces from stop() as .writeFailed instead of silently
        // dropping every cycle and reporting a truncated recording as success.
        guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let out = mixed.floatChannelData?[0]
        else {
            firstWriteError = AudioRecordingError.deviceSetupFailed("allocating mix buffer")
            return
        }
        mixed.frameLength = AVAudioFrameCount(frameCount)

        // The AGC decides on THIS cycle's levels, before they are mixed, so a
        // bleed cycle is judged on its own samples rather than the previous
        // cycle's. It still carries the tail of the previous gain: the glide
        // below starts where the last cycle ended, so the first bleed cycle
        // ramps down across its own ~10 ms rather than starting at unity.
        // Skipped wholesale when the AGC is off: no per-frame work, and the
        // mix below is then bit-identical to the pre-AGC recorder.
        let previousGain = micAGC?.appliedGain ?? 1
        if micAGC != nil {
            var micSquares: Double = 0
            var sysSquares: Double = 0
            for frame in 0..<frameCount {
                let mic = channelAverage(firstBuffer, frame: frame)
                let system = systemAverage(frame: frame)
                micSquares += Double(mic * mic)
                sysSquares += Double(system * system)
            }
            let frames = Double(frameCount)
            micAGC?.update(
                cycleRMS: Float((micSquares / frames).squareRoot()),
                systemRMS: Float((sysSquares / frames).squareRoot()),
                cycleDuration: frames / format.sampleRate
            )
        }
        // Ramp to the new gain across the cycle instead of stepping to it at
        // the boundary — a jump of up to 6x between adjacent samples is an
        // audible click. The last frame lands one step short of the target,
        // which the next cycle's ramp starts from.
        let glide = MicAGC.glide(
            from: previousGain, to: micAGC?.appliedGain ?? 1, frameCount: frameCount
        )
        var agcGain = glide.start

        for frame in 0..<frameCount {
            let mic = channelAverage(firstBuffer, frame: frame)
            let system = systemAverage(frame: frame)
            // The sidecar records the RAW pre-gain mic level on purpose:
            // RoleAssigner's «Я» heuristic compares mic vs system RMS, so
            // scaling the mic here would change what that comparison means.
            // Gated on firstWriteError so the sidecar timeline never advances
            // past where the audio file stopped.
            if firstWriteError == nil {
                activityAccumulator?.add(mic: mic, sys: system)
            }
            // The live level meter uses the same RAW pre-gain values as the
            // sidecar, and unlike it keeps running past a write error — it
            // reports what the capture hardware hears, not what the file holds.
            levelAccumulator.add(mic: mic, sys: system)
            out[frame] = tanhf(system + 0.9 * agcGain * mic)
            agcGain += glide.step
        }
        if let levels = levelAccumulator.flush(sampleRate: format.sampleRate) {
            levelsContinuation?.yield(levels)
        }
        if let lines = activityAccumulator?.flushLines(), !lines.isEmpty, let handle = activityHandle {
            do {
                try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            } catch {
                // A dropped batch would silently SHIFT every later bin earlier,
                // and even a clean prefix can mislabel «Я» (a cluster may clear
                // the share threshold on partial evidence). All-or-nothing:
                // discard the sidecar entirely.
                discardActivitySidecar()
            }
        }

        appendDownsampled(mixed)
    }

    /// Runs on writeQueue (the IO block is scheduled there by CoreAudio).
    /// The first converter/allocation/write error is latched into
    /// `firstWriteError`; every buffer after it is dropped, and `stop()`
    /// surfaces the error instead of reporting a truncated success.
    private func appendDownsampled(_ buffer: AVAudioPCMBuffer) {
        guard firstWriteError == nil, let converter, let audioFile else { return }
        let ratio = Self.outputSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            firstWriteError = AudioRecordingError.deviceSetupFailed("allocating conversion buffer")
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
            firstWriteError = conversionError
            return
        }
        guard outBuffer.frameLength > 0 else { return }
        do {
            try audioFile.write(from: outBuffer)
            framesWritten += Int64(outBuffer.frameLength)
            if let live = liveContinuation, let data = outBuffer.floatChannelData?[0] {
                let n = Int(outBuffer.frameLength)
                live.yield(Array(UnsafeBufferPointer(start: data, count: n)))
            }
        } catch {
            // Disk-full/IO error: stop accumulating silently corrupt data; the
            // partial file up to here remains decodable (CAF) after stop().
            firstWriteError = error
        }
    }

    /// Stops the activity sidecar: closes the handle and drops the accumulator.
    private func closeActivitySidecar() {
        try? activityHandle?.close()
        activityHandle = nil
        activityAccumulator = nil
    }

    /// Discards the activity sidecar (start()-failure unwind, or a mid-write
    /// failure where a partial timeline could mislabel «Я»): closes the handle
    /// and removes the file so no partial evidence survives.
    private func discardActivitySidecar() {
        closeActivitySidecar()
        if let fileURL {
            try? FileManager.default.removeItem(at: MicActivity.url(for: fileURL))
        }
    }

    // MARK: Setup helpers

    /// Creates the private aggregate device combining the default input device
    /// (mic) with the process tap. Sub-devices come before taps in the IOProc's
    /// buffer list, so buffer 0 is the mic and the remaining buffers are system
    /// audio. Throws without side effects; the caller owns tap teardown.
    private static func createAggregateDevice(tapUUID: UUID) throws -> AudioObjectID {
        let micUID = try defaultInputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Watchtower Recorder",
            kAudioAggregateDeviceUIDKey: "com.watchtower.recorder.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            throw AudioRecordingError.deviceSetupFailed("creating aggregate device (OSStatus \(status))")
        }
        return newAggregateID
    }

    /// Opens the 16 kHz mono AAC output file (CAF container — `AVAudioFile`
    /// infers it from the `.caf` URL extension; no header finalization, so an
    /// app crash mid-recording leaves a decodable file) plus the device-rate →
    /// 16 kHz converter. Sets `audioFile`/`converter`/`deviceFormat` only after
    /// every step succeeds, so on throw no partial state is left behind; the
    /// caller owns device/tap teardown.
    private func openOutputFile(url: URL) throws {
        let sampleRate = Self.nominalSampleRate(of: aggregateID)
        guard let monoDeviceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let monoOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.outputSampleRate, channels: 1, interleaved: false
        ) else {
            throw AudioRecordingError.deviceSetupFailed("building PCM formats (device rate \(sampleRate))")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Self.outputSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioRecordingError.deviceSetupFailed("opening \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let downConverter = AVAudioConverter(from: monoDeviceFormat, to: monoOutputFormat) else {
            throw AudioRecordingError.deviceSetupFailed("creating 16 kHz converter")
        }
        audioFile = file
        converter = downConverter
        deviceFormat = monoDeviceFormat
    }

    // MARK: Device helpers

    private func teardownDevices() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        teardownTap()
    }

    private func teardownTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultInputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioRecordingError.deviceSetupFailed("no default input device (OSStatus \(status))")
        }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw AudioRecordingError.deviceSetupFailed("reading input device UID (OSStatus \(status))")
        }
        return uid as String
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return 48_000 }
        return rate
    }
}
