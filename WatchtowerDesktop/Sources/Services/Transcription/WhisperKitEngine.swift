import Foundation
import WhisperKit

/// Loads/holds one WhisperKit model instance and adapts it to `TranscriptionEngine`.
///
/// This adapter exists to contain WhisperKit API churn: everything version-specific
/// (config shape, the misspelled `detectLangauge(audioArray:)`, log-prob semantics)
/// stays inside this file.
///
/// `@unchecked Sendable`: WhisperKit itself is not Sendable, but `WindowedTranscriber`
/// awaits every engine call sequentially, so the instance is never used concurrently.
final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    private let whisperKit: WhisperKit

    private init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    /// modelName e.g. "large-v3"; downloadProgress reports 0…1 during first-run model download.
    ///
    /// Uses the explicit download-then-load path because `WhisperKit(WhisperKitConfig(model:))`
    /// offers no download-progress hook in 0.18.0; `WhisperKit.download` is incremental
    /// (already-complete files are skipped), so repeat loads are fast and offline-safe.
    static func load(
        modelName: String,
        downloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperKitEngine {
        downloadProgress(0)
        let modelFolder = try await WhisperKit.download(variant: modelName) { progress in
            downloadProgress(progress.fractionCompleted)
        }
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

    func transcribeWindow(_ samples: [Float], language: String) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
