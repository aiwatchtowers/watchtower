import Foundation
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
    private let whisperKit: WhisperKit

    private init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
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

    /// Encodes the conditioning prompt the way WhisperKit's own CLI does: a
    /// leading space, special tokens filtered out (the decoder prepends
    /// `<|startofprev|>` itself and trims the rest to half the context).
    /// nil whenever there is nothing to condition on or the tokenizer is not
    /// loaded — the window then decodes exactly as it did before.
    private func promptTokens(for prompt: String?) -> [Int]? {
        guard let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let tokenizer = whisperKit.tokenizer
        else { return nil }
        let tokens = tokenizer.encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    func transcribeWindow(_ samples: [Float], language: String, prompt: String?) async throws -> [TranscribedSegment] {
        try await decodeWithPromptFallback(promptTokens: promptTokens(for: prompt)) { tokens in
            try await decode(samples, language: language, promptTokens: tokens)
        }
    }

    private func decode(_ samples: [Float], language: String, promptTokens: [Int]?) async throws -> [TranscribedSegment] {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens
        )
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        // result.text is derived from result.segments in WhisperKit, so
        // mapping segments (not text) cannot drop speech.
        return results.flatMap { result in
            result.segments.map {
                TranscribedSegment(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    startSec: Double($0.start),
                    endSec: Double($0.end)
                )
            }
        }
    }
}

/// Decodes one window, retrying ONCE without the prompt when a prompted decode
/// came back empty: a prompted decode can collapse to an immediate end-of-text
/// on audio that decodes fine clean; prompt is advisory, so an empty prompted
/// window retries once without it — genuine silence stays silent (the clean
/// retry is empty too), at the cost of a double decode on silent-after-speech
/// windows.
///
/// Lives at the engine level so batch and live inherit it identically, and takes
/// the decode step as a closure so the retry rule is testable without loading a
/// model.
func decodeWithPromptFallback(
    promptTokens: [Int]?,
    decode: ([Int]?) async throws -> [TranscribedSegment]
) async rethrows -> [TranscribedSegment] {
    let segments = try await decode(promptTokens)
    guard promptTokens != nil, !containsSpeech(segments) else { return segments }
    return try await decode(nil)
}

/// Whether a decode produced anything usable, under the same trimming rule
/// `liftWindowSegments` applies downstream.
private func containsSpeech(_ segments: [TranscribedSegment]) -> Bool {
    segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
