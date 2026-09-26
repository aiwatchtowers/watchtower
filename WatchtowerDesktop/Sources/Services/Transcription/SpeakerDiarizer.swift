import Foundation

/// One diarized interval. `speakerID` is an opaque cluster label, stable only
/// within a single diarization run. `embedding` is the cluster's L2-normalized
/// voice embedding (256-dim for FluidAudio) when the engine produces one; nil
/// otherwise — every consumer must degrade to embedding-less behavior (no
/// voice matching, no voice-print learning).
struct SpeakerSegment: Equatable, Sendable {
    let speakerID: String
    let startSec: Double
    let endSec: Double
    let embedding: [Float]?

    init(speakerID: String, startSec: Double, endSec: Double, embedding: [Float]? = nil) {
        self.speakerID = speakerID
        self.startSec = startSec
        self.endSec = endSec
        self.embedding = embedding
    }
}

/// Abstraction over the speaker-diarization engine so tests never load CoreML.
protocol SpeakerDiarizing: Sendable {
    /// Speaker timeline for a full recording (16 kHz mono Float32 samples).
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment]
}
