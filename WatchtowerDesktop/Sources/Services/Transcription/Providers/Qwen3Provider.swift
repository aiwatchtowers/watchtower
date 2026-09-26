import Foundation
import Qwen3ASR
import MLX

/// Adapts soniqo/speech-swift's `Qwen3ASRModel` (MLX, Metal + Apple Neural Engine)
/// to the pluggable `TranscriptionProvider` contract. The package's public
/// `Qwen3ASRModel.transcribe` is a plain synchronous whole-buffer call whose
/// memory grows with clip length (~0.6 GB GPU peak per audio minute), so both
/// batch and live decode through `Qwen3Windower` — WindowPlanner windows,
/// one bounded `transcribe` call each. Live input is our own loop (speech-swift
/// 0.0.7 has no live-input API; its StreamingASR takes a complete buffer).
///
/// Pinned to speech-swift **0.0.7** exactly: it is the newest tag that still
/// declares `.macOS(.v14)` (0.0.8+ requires macOS 15, via MLXState) and predates
/// the package's own `WhisperKit >=1.0.0` dependency (introduced at 0.0.20), which
/// would conflict with our `WhisperKitProvider` pin to the 0.18.x API surface. See
/// `.superpowers/sdd/task-7-report.md` for the verified version matrix.
struct Qwen3Provider: TranscriptionProvider {
    static var id: String { "qwen3" }
    var displayName: String { "Qwen3-ASR" }
    var models: [TranscriptionModelOption] {
        [.init(id: "Qwen3-ASR-0.6B", label: "Qwen3-ASR 0.6B")]
    }
    var supportsLive: Bool { true }

    /// `Qwen3ASRModel` runs its encoder/decoder on MLX (Metal + Apple Neural
    /// Engine); mlx-swift itself is documented as Apple-Silicon-only (no CPU/Intel
    /// fallback), so this mirrors `ParakeetProvider`'s Apple Silicon gate rather
    /// than returning unconditional `.available`.
    func availability() -> ProviderAvailability {
        Self.isAppleSilicon ? .available : .unavailable(reason: "Requires Apple Silicon")
    }

    /// The 30 languages + Cantonese Qwen3-ASR-0.6B was benchmark-validated on
    /// (Qwen3-ASR Technical Report / QwenLM/Qwen3-ASR model card), converted to
    /// ISO codes. `uk` (Ukrainian) is not in that official 30-language benchmark
    /// list, but is added here regardless: Qwen3's underlying multilingual
    /// tokenizer/training corpus spans 100+ languages including Slavic/Cyrillic
    /// ones, and Watchtower's ru/uk/en trilingual requirement (`TranscriptionConfig
    /// .langset`) needs it declared — this list is an upper bound of "worth
    /// routing to this model", not a certified-quality guarantee.
    func supportedLanguages(model: String) -> Set<String>? {
        ["zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi",
         "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu",
         "mk", "ro", "uk"]
    }

    /// The single HuggingFace MLX weights bundle backing our one listed model
    /// option. `Qwen3ASRModel.fromPretrained` auto-detects size/quantization from
    /// this id.
    private static let huggingFaceModelId = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"

    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await Qwen3ASRModel.fromPretrained(modelId: Self.huggingFaceModelId) { fraction, _ in
            progress(fraction)
        }
    }

    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        let asrModel = try await Qwen3ASRModel.fromPretrained(modelId: Self.huggingFaceModelId) { fraction, _ in
            progress(fraction)
        }
        return Qwen3Transcriber(model: asrModel)
    }

    /// Compile-time architecture gate — the arm64 slice of a universal binary is
    /// the only one that ever runs on genuine Apple Silicon (an x86_64 slice
    /// running under Rosetta reports false here, correctly, since MLX/Metal ANE
    /// acceleration is not available under translation either).
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

/// Wraps a loaded `Qwen3ASRModel` behind `Qwen3Windower`: batch wraps the full
/// buffer in a single-yield stream, live runs the recorder's real stream —
/// one code path, so batch and live cannot drift. Each ~20 s window is one
/// bounded `transcribe` call instead of the whole clip in one shot.
/// `@unchecked Sendable` is sound here: one instance is created per recording,
/// decode calls are serial inside one windower run, never shared concurrently
/// (same single-use invariant as `WhisperKitEngine`; the Qwen3 model is
/// documented upstream as not thread-safe, which this usage respects).
final class Qwen3Transcriber: Transcriber, @unchecked Sendable {
    private let model: Qwen3ASRModel
    init(model: Qwen3ASRModel) { self.model = model }

    private func windower(config: TranscriptionConfig) -> Qwen3Windower {
        let model = self.model
        let forced = config.forcedLanguage
        // `transcribe` strips any auto-detected "language XX" prefix internally
        // (see the package's `generateText`), so with no forced language the
        // model auto-detects per window and no tag reaches the text.
        return Qwen3Windower(config: config) { window in
            // Silence-snapped windows vary in shape, so MLX's buffer cache
            // almost never reuses them and grows without bound across a long
            // recording (measured: 3.9→8.2 GB over 32 windows of a 10-min
            // clip). Clearing per window keeps the whole run near the
            // single-window peak; the realloc cost is noise next to decode.
            defer { MLX.Memory.clearCache() }
            return model.transcribe(audio: window, sampleRate: 16_000, language: forced)
        }
    }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        let planner = WindowPlanner(config: config)
        let total = planner.planWindows(total: samples.count) { samples[$0] }.count
        let stream = AsyncStream<[Float]> { continuation in
            continuation.yield(samples)
            continuation.finish()
        }
        return try await windower(config: config)
            .run(samples: stream, windowTotal: total, progress: progress) { _ in }
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? {
        Qwen3LiveSession(windower: windower(config: config))
    }
}

/// Live session over the same windower (see `Qwen3Transcriber` for the
/// single-use `@unchecked Sendable` justification).
final class Qwen3LiveSession: TranscriptionLiveSession, @unchecked Sendable {
    let windower: Qwen3Windower
    init(windower: Qwen3Windower) { self.windower = windower }

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        try await windower.run(samples: samples, windowTotal: 0, progress: { _, _ in }, onChunk: onChunk)
    }
}
