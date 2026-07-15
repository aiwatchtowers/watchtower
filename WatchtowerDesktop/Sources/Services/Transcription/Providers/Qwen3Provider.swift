import Foundation
import Qwen3ASR

/// Adapts soniqo/speech-swift's `Qwen3ASRModel` (MLX, Metal + Apple Neural Engine)
/// to the pluggable `TranscriptionProvider` contract. Batch-only — the package's
/// public `Qwen3ASRModel.transcribe` call is a plain synchronous batch API with no
/// streaming/session surface, so `supportsLive` is false and `makeLiveSession`
/// always returns nil.
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
    var supportsLive: Bool { false }

    /// `Qwen3ASRModel` runs its encoder/decoder on MLX (Metal + Apple Neural
    /// Engine); mlx-swift itself is documented as Apple-Silicon-only (no CPU/Intel
    /// fallback), so this mirrors `ParakeetProvider`'s Apple Silicon gate rather
    /// than returning unconditional `.available`.
    func availability() -> ProviderAvailability {
        Qwen3Provider.isAppleSilicon ? .available : .unavailable(reason: "Requires Apple Silicon")
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

/// Wraps a loaded `Qwen3ASRModel`. `Qwen3ASRModel.transcribe(audio:sampleRate:)`
/// performs its own internal mel-feature extraction and audio encoding over the
/// full clip (no chunked/sliding-window API is exposed), so this wrapper does NOT
/// window like `WindowedTranscriber` — it hands the full 16 kHz buffer to the SDK
/// in one call, same as `ParakeetTranscriber`.
/// `@unchecked Sendable` is sound here: one instance is created per recording and its
/// `transcribe` is awaited once from a single detached task, never shared concurrently
/// (same single-use invariant as `WhisperKitEngine`; the Qwen3 model is documented
/// upstream as not thread-safe, which this usage respects).
final class Qwen3Transcriber: Transcriber, @unchecked Sendable {
    private let model: Qwen3ASRModel
    init(model: Qwen3ASRModel) { self.model = model }

    func transcribe(_ samples: [Float], config: TranscriptionConfig,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TranscriptionOutput {
        progress(0, 1)
        // `transcribe` is a synchronous (blocking) MLX decode call — no async
        // overload is exposed, so we call it directly from this async context.
        let text = model.transcribe(audio: samples, sampleRate: 16_000)
        progress(1, 1)
        // Qwen3ASRModel strips any auto-detected "language XX" prefix internally
        // before returning (see the package's `generateText`), so no per-utterance
        // language tag reaches callers — langStats stays empty, best-effort per
        // the pluggable-provider contract.
        return TranscriptionOutput(text: text, langStats: [:])
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? { nil }
}
