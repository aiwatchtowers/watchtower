import Foundation

/// Adapts the existing on-device WhisperKit engine to the pluggable
/// `TranscriptionProvider` contract. `large-v3-v20240930` (turbo) stays first/default,
/// matching the shipped `TranscriptionSettingsView` model picker.
struct WhisperKitProvider: TranscriptionProvider {
    static var id: String { "whisperkit" }
    var displayName: String { "WhisperKit (Whisper)" }
    var models: [TranscriptionModelOption] {
        [
            .init(id: "large-v3-v20240930", label: "Large v3 Turbo (recommended)"),
            .init(id: "large-v3", label: "Large v3 (best quality)"),
            .init(id: "distil-large-v3", label: "Distil Large v3 (English only)"),
            .init(id: "medium", label: "Medium (fastest)")
        ]
    }
    var supportsLive: Bool { true }
    func availability() -> ProviderAvailability { .available }
    func supportedLanguages(model: String) -> Set<String>? { nil }

    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKitEngine.ensureModelFilesDownloaded(modelName: model, downloadProgress: progress)
    }

    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber {
        let engine = try await WhisperKitEngine.load(modelName: model, downloadProgress: progress)
        return WhisperTranscriber(engine: engine)
    }
}

/// Wraps a loaded WhisperKitEngine, reusing the existing batch/live orchestrators
/// verbatim so their behavior (and the live↔batch pin test) is unchanged.
/// The speech detector (spec D2) is created on the first call whose config
/// has `speechGate` on — the config only arrives here — and reused for the
/// transcriber's lifetime; a gate-off config (dictation) never creates one.
final class WhisperTranscriber: Transcriber, @unchecked Sendable {
    private let engine: WhisperKitEngine
    private let lock = NSLock()
    private var detector: SileroSpeechDetector?
    init(engine: WhisperKitEngine) { self.engine = engine }

    private func speechDetector(for config: TranscriptionConfig) -> SpeechDetector? {
        guard config.speechGate else { return nil }
        return lock.withLock {
            if let detector { return detector }
            let created = SileroSpeechDetector()
            detector = created
            return created
        }
    }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        let transcriber = WindowedTranscriber(engine: engine, config: config,
                                              speechDetector: speechDetector(for: config))
        return try await transcriber.transcribe(samples: samples, progress: progress)
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? {
        WhisperLiveSession(engine: engine, config: config, speechDetector: speechDetector(for: config))
    }
}

/// Thin forwarder: conforms `StreamingTranscriber` to `TranscriptionLiveSession`.
struct WhisperLiveSession: TranscriptionLiveSession {
    let engine: WhisperKitEngine
    let config: TranscriptionConfig
    let speechDetector: SpeechDetector?
    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        try await StreamingTranscriber(engine: engine, config: config, speechDetector: speechDetector)
            .run(samples: samples, onChunk: onChunk)
    }
}
