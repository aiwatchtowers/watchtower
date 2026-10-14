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

    /// On-disk sizes of the Core ML folders, measured; `small` and `base`
    /// are the dictation-only variants.
    func downloadSizeBytes(model: String) -> Int64? {
        [
            "large-v3-v20240930": 1_600_000_000,
            "large-v3": 3_100_000_000,
            "distil-large-v3": 1_500_000_000,
            "medium": 1_500_000_000,
            "small": 490_000_000,
            "base": 150_000_000
        ][model]
    }

    /// The Hub cache folder WhisperKit downloads into — HubApi's default
    /// base (Documents/huggingface) plus the repo — holds one folder per
    /// variant, named "<family>_<model>" or "<family>-<model>". Present =
    /// both weight files landed (the Hub moves each file in only once it is
    /// complete).
    func modelFilesMissing(model: String) -> Bool {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let repo = documents.appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")
        guard let folders = try? fileManager.contentsOfDirectory(atPath: repo.path) else { return true }
        return !folders.contains { name in
            guard name.hasSuffix("_\(model)") || name.hasSuffix("-\(model)") else { return false }
            let folder = repo.appending(path: name)
            return ["AudioEncoder", "TextDecoder"].allSatisfy {
                fileManager.fileExists(atPath: folder.appending(path: "\($0).mlmodelc/weights/weight.bin").path)
            }
        }
    }

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
/// The speech detector (spec D2) comes from the transcriber's `SpeechDetectorSlot`.
final class WhisperTranscriber: Transcriber, @unchecked Sendable {
    private let engine: WhisperKitEngine
    private let detectors = SpeechDetectorSlot()
    init(engine: WhisperKitEngine) { self.engine = engine }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        let transcriber = WindowedTranscriber(engine: engine, config: config,
                                              speechDetector: detectors.detector(for: config))
        return try await transcriber.transcribe(samples: samples, progress: progress)
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? {
        WhisperLiveSession(engine: engine, config: config, speechDetector: detectors.detector(for: config))
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
