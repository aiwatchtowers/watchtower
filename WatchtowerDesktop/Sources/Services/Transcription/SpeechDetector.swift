import Foundation
import FluidAudio
import WatchtowerCore

/// Finds the speech in one window of 16 kHz mono samples (spec D1). Ranges
/// are sample offsets relative to `samples`, sorted, non-overlapping and
/// already padded. Stateless across calls — the same samples always give the
/// same ranges — which is what keeps the live and batch paths equivalent:
/// both ask on identical window samples. (A model that is not loaded yet
/// breaks that for the windows it misses; see `SpeechDetectorNotReady`.)
protocol SpeechDetector: Sendable {
    func speechRanges(in samples: [Float]) async throws -> [Range<Int>]
    /// The same, waiting at most `modelWait` for a model still loading
    /// before throwing `SpeechDetectorNotReady` (`.zero` = only if loaded,
    /// nil = until it loads). Detectors without a model keep the default.
    func speechRanges(in samples: [Float], modelWait: Duration?) async throws -> [Range<Int>]
}

extension SpeechDetector {
    func speechRanges(in samples: [Float], modelWait: Duration?) async throws -> [Range<Int>] {
        try await speechRanges(in: samples)
    }
}

extension EnergySpeechDetector: SpeechDetector {}

/// The detector's model is still loading (or downloading), or a failed load
/// is not due for another attempt yet: the gate decides this window with the
/// energy detector and asks again, without waiting, on the next one (board
/// #564).
struct SpeechDetectorNotReady: Error {}

/// The detector's model failed to load. Wrapped so nothing the load throws
/// (a `CancellationError` included) reads as the caller's own cancel.
struct SpeechDetectorLoadFailed: Error {
    let underlying: Error
}

/// The production detector: FluidAudio's Silero VAD (CoreML) and its
/// segmentation. The model loads on the first window, downloading on first
/// use like the diarizer, and stays loaded. The load runs in the background
/// (`BackgroundLoad`): a caller waits for it at most its `modelWait` — the
/// gate pays one bounded wait per run (`WindowSpeechGate.liveModelWait` /
/// `batchModelWait`) and polls without waiting after that — and past it gets
/// `SpeechDetectorNotReady` while the load goes on. A failed load throws
/// `SpeechDetectorLoadFailed` to the windows waiting on it (logged when none
/// is) and is not remembered: a later window starts a new attempt, at most
/// one a minute.
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

    /// A segmentation pass over one window with the loaded model.
    typealias Segmenter = @Sendable (_ samples: [Float]) async throws -> [Range<Int>]

    private let model: BackgroundLoad<Segmenter>

    /// The parameters are for the corpus tuning bench; production uses the defaults.
    init(
        threshold: Float = defaultThreshold,
        minSpeechSec: Double = defaultMinSpeechSec,
        minSilenceSec: Double = defaultMinSilenceSec,
        paddingSec: Double = defaultPaddingSec
    ) {
        let segmentation = VadSegmentationConfig(
            minSpeechDuration: minSpeechSec,
            minSilenceDuration: minSilenceSec,
            maxSpeechDuration: .infinity,
            speechPadding: paddingSec
        )
        self.init(model: BackgroundLoad(onUnobservedFailure: Self.logUnobservedFailure) {
            do {
                let manager = try await VadManager(config: VadConfig(defaultThreshold: threshold))
                return { samples in
                    let rate = TranscriptionConfig.sampleRate
                    return SpeechGate.merged(try await manager.segmentSpeech(samples, config: segmentation).map {
                        let start = min(max(0, $0.startSample(sampleRate: rate)), samples.count)
                        return start..<min(max(start, $0.endSample(sampleRate: rate)), samples.count)
                    })
                }
            } catch {
                throw SpeechDetectorLoadFailed(underlying: error)
            }
        })
    }

    /// `model` replaces the Silero load (tests).
    init(model: BackgroundLoad<Segmenter>) {
        self.model = model
    }

    /// Fetches the model ahead of a recording (Settings/Calendar warmup).
    static func prefetchModel() async throws {
        _ = try await VadManager(config: VadConfig(defaultThreshold: defaultThreshold))
    }

    /// Waits for the model until it loads (the bench).
    func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
        try await speechRanges(in: samples, modelWait: nil)
    }

    func speechRanges(in samples: [Float], modelWait: Duration?) async throws -> [Range<Int>] {
        guard let segment = try await model.value(waitingUpTo: modelWait) else { throw SpeechDetectorNotReady() }
        return try await segment(samples)
    }

    @Sendable private static func logUnobservedFailure(_ error: Error) {
        let cause = (error as? SpeechDetectorLoadFailed)?.underlying ?? error
        NSLog("SpeechGate: speech detector model failed to load (%@) — a later window tries again",
              String(describing: type(of: cause)))
    }
}
