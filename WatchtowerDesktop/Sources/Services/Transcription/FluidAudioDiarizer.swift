import FluidAudio
import Foundation

/// Adapts FluidAudio's offline (pyannote + VBx) diarization pipeline to
/// `SpeakerDiarizing`. Everything FluidAudio-specific stays inside this file,
/// the same way WhisperKitEngine contains WhisperKit churn.
///
/// `@unchecked Sendable`: DiarizerManager is not Sendable, but the Center
/// runs at most one diarization at a time per loaded instance.
final class FluidAudioDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let manager: DiarizerManager

    private init(manager: DiarizerManager) {
        self.manager = manager
    }

    /// Downloads the diarizer models on first use (HuggingFace, then cached
    /// on disk) and initializes the pipeline.
    static func load() async throws -> FluidAudioDiarizer {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return FluidAudioDiarizer(manager: manager)
    }

    /// Model prefetch without keeping an instance (Settings/Calendar warmup).
    static func prefetchModels() async throws {
        _ = try await DiarizerModels.downloadIfNeeded()
    }

    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] {
        let manager = self.manager
        // performCompleteDiarization is synchronous and heavy — run it off
        // the caller's (main) actor.
        return try await Task.detached(priority: .userInitiated) {
            let result = try manager.performCompleteDiarization(
                samples, sampleRate: TranscriptionConfig.sampleRate
            )
            // Per-speaker centroid embeddings: DiarizationResult.speakerDatabase
            // is populated only in debugMode, so fall back to the manager's
            // speaker database (the same source it is built from); a segment's
            // own embedding is the last resort. Consumers treat nil as
            // "no voice identity available".
            let speakerDB = result.speakerDatabase
                ?? manager.speakerManager.getAllSpeakers().mapValues { $0.currentEmbedding }
            return result.segments.map {
                SpeakerSegment(
                    speakerID: $0.speakerId,
                    startSec: Double($0.startTimeSeconds),
                    endSec: Double($0.endTimeSeconds),
                    embedding: speakerDB[$0.speakerId] ?? $0.embedding
                )
            }
        }.value
    }
}
