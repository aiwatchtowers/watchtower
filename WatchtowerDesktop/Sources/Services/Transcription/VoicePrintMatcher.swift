import Foundation
import WatchtowerCore

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

    /// Normalization shared by every print↔identity compare in this file:
    /// trim + case-fold, symmetric on both sides. Must stay in step with the
    /// print writer `SpeakerNaming.personKey(for:attendees:)` (VoicePrint.swift)
    /// — if the two drift, a print minted by the rename path becomes
    /// invisible to the scoping/owner paths.
    private static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when the print belongs to the machine's owner: its `personKey` is
    /// one of the owner's email identities. Both sides are normalized HERE —
    /// no caller-side lowercasing contract to silently break. A name-keyed
    /// print (minted by an ad-hoc/free-text rename) is never recognizable as
    /// the owner's — callers must disarm owner-dependent logic in that case
    /// rather than treat the owner as a stranger.
    static func isOwnerPrint(_ print: VoicePrint, ownerEmails: Set<String>) -> Bool {
        let printKey = key(print.personKey)
        return ownerEmails.contains { key($0) == printKey }
    }

    /// Restricts the voice-print pool to the event's attendees: a print is
    /// kept when its `personKey` or `displayName` matches an attendee's email
    /// or display name (case-insensitive, empty fields never match — some
    /// rows legitimately carry only one of the two; room resources are
    /// filtered upstream in `CalendarEvent.attendeesIncludingOrganizer`).
    /// An empty attendee list means an ad-hoc recording — matching stays
    /// global, everything is kept. This is
    /// what keeps a voice-alike stranger from another meeting out of an
    /// event-linked transcript. The owner's EMAIL-KEYED prints (`ownerEmails`,
    /// via `isOwnerPrint`) always survive scoping — the owner is present at
    /// their own recording by definition, whatever the attendee list says; a
    /// name-keyed owner print is not recognizable as the owner's and follows
    /// the ordinary attendee rules.
    static func scoped(
        _ prints: [VoicePrint],
        attendees: [EventAttendee],
        ownerEmails: Set<String>
    ) -> [VoicePrint] {
        guard !attendees.isEmpty else { return prints }
        let known = Set(attendees.flatMap { [key($0.email), key($0.displayName)] }
            .filter { !$0.isEmpty })
        return prints.filter {
            known.contains(key($0.personKey))
                || known.contains(key($0.displayName))
                || isOwnerPrint($0, ownerEmails: ownerEmails)
        }
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
