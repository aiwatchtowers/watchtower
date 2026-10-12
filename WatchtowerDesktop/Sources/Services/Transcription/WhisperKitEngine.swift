import Foundation
import WatchtowerCore
import WhisperKit

/// Loads/holds one WhisperKit model instance and adapts it to `WhisperWindowEngine`.
///
/// This adapter exists to contain WhisperKit API churn: everything version-specific
/// (config shape, the misspelled `detectLangauge(audioArray:)`, log-prob semantics)
/// stays inside this file.
///
/// `@unchecked Sendable`: WhisperKit itself is not Sendable, but `WindowedTranscriber`
/// awaits every engine call sequentially, so the instance is never used concurrently.
final class WhisperKitEngine: WhisperWindowEngine, @unchecked Sendable {
    /// Every language code Whisper's detector can answer with.
    static let languageCodes: Set<String> = Constants.languageCodes

    private let whisperKit: WhisperKit
    private let dropLock = NSLock()
    private var drops = WindowDropCounts()

    /// Bench seam: sees every decoded segment with its confidence before L3
    /// decides. nil in production.
    var segmentScoreObserver: (@Sendable (ScoredWhisperSegment) -> Void)?

    private init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    /// The decode options, every threshold L3 relies on pinned explicitly
    /// (spec D3) so a WhisperKit upgrade cannot move them. Chunking stays
    /// off: our windows are already at most 30 s.
    static func decodingOptions(language: String, promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 5,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens,
            compressionRatioThreshold: WhisperSegmentConfidence.compressionRatioThreshold,
            logProbThreshold: WhisperSegmentConfidence.logProbThreshold,
            noSpeechThreshold: WhisperSegmentConfidence.noSpeechThreshold,
            chunkingStrategy: nil
        )
    }

    /// L3's inputs for one segment, from the segment's OWN text tokens
    /// (timestamps and other special tokens, ids ≥ `specialTokenBegin`,
    /// excluded): the mean log-probability and the zlib compression ratio.
    /// WhisperKit 0.18 copies one decode pass's `avgLogprob` and
    /// `compressionRatio` onto every segment of the pass, so judging those
    /// would let one looping or doubtful segment drop the real speech beside
    /// it. A segment without text tokens falls back to the pass values.
    static func segmentScore(
        tokens: [Int],
        tokenLogProbs: [[Int: Float]],
        specialTokenBegin: Int,
        passAvgLogprob: Float,
        passCompressionRatio: Float
    ) -> WhisperSegmentScore {
        let textTokens = tokens.filter { $0 < specialTokenBegin }
        let logprobs = tokenLogProbs.flatMap { $0.filter { $0.key < specialTokenBegin }.map(\.value) }
        return WhisperSegmentScore(
            avgLogprob: logprobs.isEmpty ? passAvgLogprob : logprobs.reduce(0, +) / Float(logprobs.count),
            compressionRatio: textTokens.isEmpty ? passCompressionRatio : TextUtilities.compressionRatio(of: textTokens)
        )
    }

    func takeDropCounts() -> WindowDropCounts {
        dropLock.withLock {
            defer { drops = WindowDropCounts() }
            return drops
        }
    }

    /// Downloads `modelName`'s files to the local WhisperKit cache without
    /// instantiating the model. `TranscriptionModelProvisioner` calls this to
    /// prefetch ahead of a recording; `load` below reuses it so the two
    /// callers never diverge on how a download is performed. `WhisperKit.download`
    /// is incremental (already-complete files are skipped), so calling this
    /// again from `load` after a prefetch already finished is a fast on-disk
    /// check, not a re-download.
    static func ensureModelFilesDownloaded(
        modelName: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(variant: modelName) { progress in
            downloadProgress(progress.fractionCompleted)
        }
    }

    /// modelName e.g. "large-v3"; downloadProgress reports 0…1 during first-run model download.
    ///
    /// Uses the explicit download-then-load path because `WhisperKit(WhisperKitConfig(model:))`
    /// offers no download-progress hook in 0.18.0.
    static func load(
        modelName: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperKitEngine {
        downloadProgress(0)
        let modelFolder = try await ensureModelFilesDownloaded(modelName: modelName, downloadProgress: downloadProgress)
        downloadProgress(1)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            load: true
        )
        let whisperKit = try await WhisperKit(config)
        return WhisperKitEngine(whisperKit: whisperKit)
    }

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] {
        // [sic] "Langauge" — the audioArray variant is misspelled in WhisperKit 0.18.0.
        let result = try await whisperKit.detectLangauge(audioArray: samples)
        // WhisperKit reports log-probabilities for the sampled language token;
        // WindowedTranscriber's threshold/margin expect linear probabilities
        // (snoop/faster-whisper semantics), so convert via exp.
        var probs: [String: Float] = [:]
        probs.reserveCapacity(result.langProbs.count)
        for (language, logProb) in result.langProbs {
            probs[language] = exp(min(logProb, 0))
        }
        return probs
    }

    /// nil when the tokenizer is not loaded — the window then decodes exactly
    /// as it did before prompts existed. Encoding rules live in the pure
    /// `whisperPromptTokens`.
    private func promptTokens(for prompt: String?) -> [Int]? {
        guard let tokenizer = whisperKit.tokenizer else { return nil }
        return whisperPromptTokens(prompt, specialTokenBegin: tokenizer.specialTokens.specialTokenBegin) {
            tokenizer.encode(text: $0)
        }
    }

    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
        try await decodeWithPromptFallback(promptTokens: promptTokens(for: prompt)) { tokens in
            try await decode(samples, language: language, promptTokens: tokens)
        }
    }

    private func decode(_ samples: [Float], language: String, promptTokens: [Int]?) async throws -> [TranscribedSegment] {
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: Self.decodingOptions(language: language, promptTokens: promptTokens)
        )
        // result.text is derived from result.segments in WhisperKit, so
        // mapping segments (not text) cannot drop speech; L3 then drops the
        // segments the model itself doubts, and the filter removes only
        // Whisper's known subtitle-credit boilerplate.
        let specialTokenBegin = whisperKit.tokenizer?.specialTokens.specialTokenBegin ?? Int.max
        let (confident, confidenceCounts) = Self.confidentSegments(results.flatMap(\.segments),
                                                                   specialTokenBegin: specialTokenBegin,
                                                                   observer: segmentScoreObserver)
        var counts = confidenceCounts
        let cleaned = confident.withoutHallucinations()
        counts.phrase += confident.count - cleaned.count
        counts.droppedChars += confident.map(\.text.count).reduce(0, +) - cleaned.map(\.text.count).reduce(0, +)
        dropLock.withLock { drops.add(counts) }
        return cleaned
    }

    /// L3 over one decode's segments: maps each to a `TranscribedSegment`
    /// and drops those `WhisperSegmentConfidence` rejects on the segment's
    /// own score. Pure apart from the bench observer.
    static func confidentSegments(
        _ segments: [TranscriptionSegment],
        specialTokenBegin: Int,
        observer: (@Sendable (ScoredWhisperSegment) -> Void)? = nil
    ) -> (segments: [TranscribedSegment], counts: WindowDropCounts) {
        var counts = WindowDropCounts()
        let kept = segments.compactMap { segment -> TranscribedSegment? in
            let mapped = TranscribedSegment(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startSec: Double(segment.start),
                endSec: Double(segment.end)
            )
            let score = segmentScore(tokens: segment.tokens, tokenLogProbs: segment.tokenLogProbs,
                                     specialTokenBegin: specialTokenBegin,
                                     passAvgLogprob: segment.avgLogprob,
                                     passCompressionRatio: segment.compressionRatio)
            let reason = WhisperSegmentConfidence.dropReason(
                noSpeechProb: segment.noSpeechProb,
                avgLogprob: score.avgLogprob,
                compressionRatio: score.compressionRatio
            )
            observer?(ScoredWhisperSegment(segment: mapped, noSpeechProb: segment.noSpeechProb, score: score,
                                           temperature: segment.temperature, dropReason: reason))
            guard reason == nil else {
                counts.confidence += 1
                counts.droppedChars += mapped.text.count
                return nil
            }
            return mapped
        }
        return (kept, counts)
    }
}

/// What L3 judges a segment by (see `WhisperKitEngine.segmentScore`).
struct WhisperSegmentScore: Equatable, Sendable {
    let avgLogprob: Float
    let compressionRatio: Float
}

/// One decoded segment with the confidence L3 judged it by (bench seam).
struct ScoredWhisperSegment: Sendable {
    let segment: TranscribedSegment
    let noSpeechProb: Float
    let score: WhisperSegmentScore
    let temperature: Float
    let dropReason: WhisperSegmentConfidence.Reason?
}
