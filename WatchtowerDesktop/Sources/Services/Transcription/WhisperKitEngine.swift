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

    /// The segment's own confidence: the mean log-probability of its text
    /// tokens (timestamps and other special tokens excluded). nil when the
    /// segment carries none — the caller then falls back to the decode's.
    private func textTokenLogprob(_ segment: TranscriptionSegment) -> Float? {
        let begin = whisperKit.tokenizer?.specialTokens.specialTokenBegin ?? Int.max
        let values = segment.tokenLogProbs.flatMap { $0.filter { $0.key < begin }.map(\.value) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
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
        var counts = WindowDropCounts()
        let confident = results.flatMap(\.segments).compactMap { segment -> TranscribedSegment? in
            let mapped = TranscribedSegment(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startSec: Double(segment.start),
                endSec: Double(segment.end)
            )
            let reason = WhisperSegmentConfidence.dropReason(
                noSpeechProb: segment.noSpeechProb,
                avgLogprob: textTokenLogprob(segment) ?? segment.avgLogprob,
                compressionRatio: segment.compressionRatio
            )
            segmentScoreObserver?(ScoredWhisperSegment(
                segment: mapped, noSpeechProb: segment.noSpeechProb, avgLogprob: segment.avgLogprob,
                compressionRatio: segment.compressionRatio, temperature: segment.temperature,
                textTokenLogprob: textTokenLogprob(segment), dropReason: reason
            ))
            guard reason == nil else {
                counts.confidence += 1
                counts.droppedChars += mapped.text.count
                return nil
            }
            return mapped
        }
        let cleaned = confident.withoutHallucinations()
        counts.phrase += confident.count - cleaned.count
        counts.droppedChars += confident.map(\.text.count).reduce(0, +) - cleaned.map(\.text.count).reduce(0, +)
        dropLock.withLock { drops.add(counts) }
        return cleaned
    }
}

/// One decoded segment with the confidence L3 judged it by (bench seam).
struct ScoredWhisperSegment: Sendable {
    let segment: TranscribedSegment
    let noSpeechProb: Float
    let avgLogprob: Float
    let compressionRatio: Float
    let temperature: Float
    /// Mean log-probability of the segment's own text tokens — what L3
    /// judges; `avgLogprob` is the decode pass's, shared by its segments.
    let textTokenLogprob: Float?
    let dropReason: WhisperSegmentConfidence.Reason?
}
