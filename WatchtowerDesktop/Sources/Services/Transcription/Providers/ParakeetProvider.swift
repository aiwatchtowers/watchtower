import Foundation
import FluidAudio

/// Adapts FluidAudio's Parakeet TDT v3 engine (CoreML, Apple Neural Engine) to the
/// pluggable `TranscriptionProvider` contract. Batch-only — FluidAudio ships no
/// streaming API for the multilingual v3 model (only the separate English-only
/// `parakeet-realtime-eou` model streams), so `supportsLive` is false and
/// `makeLiveSession` always returns nil.
struct ParakeetProvider: TranscriptionProvider {
    static var id: String { "parakeet" }
    var displayName: String { "Parakeet v3 (NVIDIA)" }
    var models: [TranscriptionModelOption] {
        [.init(id: "parakeet-tdt-0.6b-v3", label: "Parakeet TDT 0.6B v3")]
    }
    var supportsLive: Bool { false }
    func availability() -> ProviderAvailability {
        SystemInfo.isAppleSilicon ? .available : .unavailable(reason: "Requires Apple Silicon")
    }

    /// The 25 European languages `parakeet-tdt-0.6b-v3-coreml` was trained on
    /// (FluidInference/parakeet-tdt-0.6b-v3-coreml model card).
    func supportedLanguages(model: String) -> Set<String>? {
        ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
         "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    }

    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(version: .v3) { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        }
    }

    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        let models = try await AsrModels.downloadAndLoad(version: .v3) { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        }
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        return ParakeetTranscriber(asrManager: asrManager)
    }
}

/// Wraps a loaded FluidAudio `AsrManager`. `AsrManager.transcribe(_:decoderState:)`
/// performs its own internal long-form chunking (`ChunkProcessor`, stateless
/// windows stitched with token deduplication) for audio longer than ~15s, so this
/// wrapper does NOT window like `WindowedTranscriber` — it hands the full 16 kHz
/// buffer to FluidAudio in one call.
final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    private let asrManager: AsrManager
    init(asrManager: AsrManager) { self.asrManager = asrManager }

    func transcribe(_ samples: [Float], config: TranscriptionConfig,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        progress(0, 1)
        let decoderLayers = await asrManager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        progress(1, 1)
        // ASRResult carries no per-utterance language tag (FluidAudio does not
        // expose language detection results for the v3 batch path), so langStats
        // stays empty — best-effort per the pluggable-provider contract.
        return TranscriptionOutput(text: result.text, langStats: [:])
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
