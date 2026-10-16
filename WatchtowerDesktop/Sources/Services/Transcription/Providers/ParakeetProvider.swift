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

    func downloadSizeBytes(model: String) -> Int64? { 480_000_000 }

    func modelFilesMissing(model: String) -> Bool {
        !AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
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
        return ParakeetTranscriber { samples in
            let decoderLayers = await asrManager.decoderLayerCount
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            return try await asrManager.transcribe(samples, decoderState: &decoderState).text
        }
    }
}

/// Wraps a loaded FluidAudio `AsrManager`. `AsrManager.transcribe(_:decoderState:)`
/// performs its own internal long-form chunking (`ChunkProcessor`, stateless
/// windows stitched with token deduplication) for audio longer than ~15s, so this
/// wrapper does NOT window like `WindowedTranscriber` — it hands the full 16 kHz
/// buffer to FluidAudio in one call.
/// `@unchecked Sendable` is sound here: one instance is created per recording and its
/// `transcribe` is awaited once from a single detached task, never shared concurrently
/// (same single-use invariant as `WhisperKitEngine`).
///
/// Silence defence (spec D5, board #554): everything outside the detected
/// speech is muted to exact zeros before the whole buffer goes to the engine
/// (L5, `speechOnlyBuffer`; a recording with no speech is not decoded), and
/// the text goes through the phrase filter.
final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    /// Whole-buffer decode (production: FluidAudio `AsrManager`; tests: a fake).
    private let decode: @Sendable ([Float]) async throws -> String
    private let detectors: SpeechDetectorSlot
    init(speechDetector: SpeechDetector? = nil, decode: @escaping @Sendable ([Float]) async throws -> String) {
        detectors = SpeechDetectorSlot(detector: speechDetector)
        self.decode = decode
    }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        progress(0, 1)
        let (audio, gate) = await speechOnlyBuffer(samples, detector: detectors.detector(for: config), config: config)
        try Task.checkCancellation() // a cancelled detection is no reason to decode a half-muted buffer
        var drops = WindowDropCounts()
        defer { gate.logSummary(callerDrops: drops) }
        guard let audio else {
            progress(1, 1)
            return TranscriptionOutput(text: "", langStats: [:])
        }
        // One muted copy of the recording while it decodes: FluidAudio's
        // long-form path takes only a [Float] (its chunk source is internal),
        // and the caller keeps the original for diarization.
        let text = withoutHallucinatedPhrases(try await decode(audio.muted()), config: config, counting: &drops)
        progress(1, 1)
        // ASRResult carries no per-utterance language tag (FluidAudio does not
        // expose language detection results for the v3 batch path), so langStats
        // stays empty — best-effort per the pluggable-provider contract.
        return TranscriptionOutput(text: text, langStats: [:])
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
