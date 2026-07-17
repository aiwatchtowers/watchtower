import Foundation

/// One diarized interval. `speakerID` is an opaque cluster label, stable only
/// within a single diarization run.
struct SpeakerSegment: Equatable, Sendable {
    let speakerID: String
    let startSec: Double
    let endSec: Double
}

/// Abstraction over the speaker-diarization engine so tests never load CoreML.
protocol SpeakerDiarizing: Sendable {
    /// Speaker timeline for a full recording (16 kHz mono Float32 samples).
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment]
}
