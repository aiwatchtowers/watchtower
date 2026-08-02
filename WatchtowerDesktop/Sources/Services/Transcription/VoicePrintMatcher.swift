import Foundation

/// Pure cosine matching of diarized cluster embeddings against the
/// voice-print database, plus the incremental centroid math the rename flow
/// uses to learn a person's voice. No I/O.
enum VoicePrintMatcher {
    /// Minimum cosine similarity for a confident match (constant for now,
    /// tunable later per the spec).
    static let matchThreshold: Float = 0.7

    /// L2-normalizes a vector; nil for an empty or zero vector (a degenerate
    /// embedding must never match anything).
    static func normalize(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity = dot product of the L2-normalized vectors. nil when
    /// either vector is degenerate (zero/empty) or dimensions mismatch.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count,
              let na = normalize(a), let nb = normalize(b) else { return nil }
        return zip(na, nb).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    /// Best voice print for a cluster embedding: the highest cosine similarity
    /// at or above `matchThreshold`. Prints with corrupt or dimension-mismatched
    /// centroids are skipped; nil when nothing clears the threshold (or the
    /// database is empty).
    static func bestMatch(embedding: [Float], prints: [VoicePrint]) -> VoicePrint? {
        var best: (print: VoicePrint, score: Float)?
        for candidate in prints {
            guard let score = cosine(embedding, candidate.embeddingVector) else { continue }
            if score >= matchThreshold, score > (best?.score ?? -.infinity) {
                best = (candidate, score)
            }
        }
        return best?.print
    }

    /// Incremental centroid update for a confirmed rename:
    /// `normalize(centroid·n + embedding)` where n = current sample count.
    /// nil when the math cannot produce a valid centroid (dimension mismatch,
    /// zero result) — the caller then keeps the existing print unchanged.
    static func updatedCentroid(centroid: [Float], sampleCount: Int, embedding: [Float]) -> [Float]? {
        guard centroid.count == embedding.count, sampleCount > 0 else { return nil }
        let n = Float(sampleCount)
        let summed = zip(centroid, embedding).map { $0 * n + $1 }
        return normalize(summed)
    }
}
