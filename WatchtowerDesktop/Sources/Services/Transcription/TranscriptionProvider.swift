import Foundation

/// A model choice offered by a provider; `id` is what lands in `transcription.model`.
struct TranscriptionModelOption: Equatable, Identifiable {
    let id: String
    let label: String
}

/// Whether a provider can run on this machine right now.
enum ProviderAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// Lightweight descriptor + factory for one transcription engine family.
/// Registered in `TranscriptionProviderRegistry`; loads NO model until `makeTranscriber`.
protocol TranscriptionProvider: Sendable {
    static var id: String { get }
    var displayName: String { get }
    var models: [TranscriptionModelOption] { get }
    var supportsLive: Bool { get }
    func availability() -> ProviderAvailability
    /// nil = not language-restricted (e.g. Whisper's 99 languages).
    func supportedLanguages(model: String) -> Set<String>?
    func prefetch(model: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func makeTranscriber(model: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Transcriber
}

/// A loaded engine (holds the heavy model). Lives for one recording/decode.
protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float],
                    config: TranscriptionConfig,
                    progress: @escaping @Sendable (_ window: Int, _ total: Int) -> Void)
        async throws -> TranscriptionOutput
    /// nil when the provider does not support live (wave one: only WhisperKit).
    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession?
}

/// A live transcription session over a 16 kHz mono Float32 input stream, emitting
/// finalized chunks via `onChunk`. Signature MIRRORS the existing
/// `StreamingTranscriber.run(samples:onChunk:)` so `WhisperLiveSession` is a thin
/// forwarder. `StreamChunk` is the existing type in `StreamingTranscriber.swift`.
protocol TranscriptionLiveSession: Sendable {
    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput
}
