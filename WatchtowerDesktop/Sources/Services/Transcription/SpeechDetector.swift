import Foundation
import FluidAudio
import WatchtowerCore

/// Finds the speech in one window of 16 kHz mono samples (spec D1). Ranges
/// are sample offsets relative to `samples`, sorted, non-overlapping and
/// already padded. Stateless across calls — the same samples always give the
/// same ranges — which is what keeps the live and batch paths equivalent:
/// both ask on identical window samples.
protocol SpeechDetector: Sendable {
    func speechRanges(in samples: [Float]) async throws -> [Range<Int>]
}

extension EnergySpeechDetector: SpeechDetector {}

/// The production detector: FluidAudio's Silero VAD (CoreML) and its
/// segmentation. The model loads on the first window, downloading on first
/// use like the diarizer, and stays loaded. A load failure is not
/// remembered: the gate moves that recording to the energy fallback, and the
/// next recording tries the model again.
actor SileroSpeechDetector: SpeechDetector {
    /// Model probability that opens speech. FluidAudio's 0.85 is tuned for
    /// ASR chunking and drops quiet speech.
    ///
    /// Measured on the bench corpus (`testSpeechDetectorsOnCorpus`, 2026-10-12:
    /// 58 clips of FLEURS en/ru/uk speech — half of it recorded at −60 to −66
    /// dBFS RMS — around zeros, white/pink noise at −60/−45 dBFS, 50 Hz hum at
    /// −40 dBFS and a fade to −90 dBFS dither, windowed as production windows):
    /// every threshold from 0.35 to 0.65 skipped 0 speech-bearing windows and
    /// opened 0 filler-only windows; 0.5 covers 87.6 % of the utterance spans
    /// (the rest is the recordings' own leading/trailing silence) and 0.28 %
    /// of the filler, 0.35 covers 89.6 % / 0.44 %.
    static let defaultThreshold: Float = 0.5
    /// 0.3 s rather than the spec's 0.25: FluidAudio asserts padding ≤ min
    /// speech, and the padding stays at 0.3 s.
    static let defaultMinSpeechSec = 0.3
    static let defaultMinSilenceSec = 0.5
    static let defaultPaddingSec = 0.3

    private let threshold: Float
    private let segmentation: VadSegmentationConfig
    private var manager: VadManager?

    /// The parameters are for the corpus tuning bench; production uses the defaults.
    init(
        threshold: Float = defaultThreshold,
        minSpeechSec: Double = defaultMinSpeechSec,
        minSilenceSec: Double = defaultMinSilenceSec,
        paddingSec: Double = defaultPaddingSec
    ) {
        self.threshold = threshold
        segmentation = VadSegmentationConfig(
            minSpeechDuration: minSpeechSec,
            minSilenceDuration: minSilenceSec,
            maxSpeechDuration: .infinity,
            speechPadding: paddingSec
        )
    }

    /// Fetches the model ahead of a recording (Settings/Calendar warmup).
    static func prefetchModel() async throws {
        _ = try await VadManager(config: VadConfig(defaultThreshold: defaultThreshold))
    }

    func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
        let manager = try await loadedManager()
        let segments = try await manager.segmentSpeech(samples, config: segmentation)
        let rate = TranscriptionConfig.sampleRate
        return SpeechGate.merged(segments.map {
            let start = min(max(0, $0.startSample(sampleRate: rate)), samples.count)
            return start..<min(max(start, $0.endSample(sampleRate: rate)), samples.count)
        })
    }

    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        let loaded = try await VadManager(config: VadConfig(defaultThreshold: threshold))
        manager = loaded
        return loaded
    }
}
