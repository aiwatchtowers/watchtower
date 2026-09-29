import Foundation

/// Pure nearest-sample voice identification (spec §2.2). No I/O.
///
/// A cluster is compared against every usable sample (current model version;
/// active samples name, pending imported samples only suggest) and each
/// person scores by their single nearest sample — so a person with several
/// channel variants (room mic vs remote) is never averaged into a centroid
/// that matches neither.
package enum VoiceMatcher {
    package struct Cluster: Equatable, Sendable {
        package let label: String
        package let embedding: [Float]
        package let speechSec: Double
        /// People the owner rejected for this cluster — never assigned to it.
        package let rejectedPersonIDs: Set<Int64>

        package init(label: String, embedding: [Float], speechSec: Double, rejectedPersonIDs: Set<Int64> = []) {
            self.label = label
            self.embedding = embedding
            self.speechSec = speechSec
            self.rejectedPersonIDs = rejectedPersonIDs
        }
    }

    package enum Decision: Equatable, Sendable {
        case confident(personID: Int64, sampleID: Int64, score: Float)
        case unsure(personID: Int64?, score: Float, reason: VoiceLabelReason)
        case unknown(bestScore: Float)
        case tooShort

        /// Scores compare at 3 decimals so float noise never fails an equality.
        package static func == (lhs: Self, rhs: Self) -> Bool {
            func rounded(_ x: Float) -> Float { (x * 1000).rounded() }
            switch (lhs, rhs) {
            case let (.confident(p1, s1, x), .confident(p2, s2, y)):
                return p1 == p2 && s1 == s2 && rounded(x) == rounded(y)
            case let (.unsure(p1, x, q1), .unsure(p2, y, q2)):
                return p1 == p2 && q1 == q2 && rounded(x) == rounded(y)
            case let (.unknown(x), .unknown(y)):
                return rounded(x) == rounded(y)
            case (.tooShort, .tooShort):
                return true
            default:
                return false
            }
        }
    }

    /// L2-normalizes a vector; nil for an empty, zero or non-finite vector
    /// (a degenerate embedding must never match anything).
    package static func normalize(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity; nil when either vector is degenerate or the
    /// dimensions differ.
    package static func cosine(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, let na = normalize(a), let nb = normalize(b) else { return nil }
        return zip(na, nb).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }

    /// Best sample per person, highest first. Samples without an id or with
    /// an unusable vector are skipped.
    package static func nearest(embedding: [Float],
                                samples: [VoiceSample]) -> [(personID: Int64, sampleID: Int64, score: Float)] {
        var best: [Int64: (sampleID: Int64, score: Float)] = [:]
        for sample in samples {
            guard let sampleID = sample.id, let score = cosine(embedding, sample.vector) else { continue }
            if score > (best[sample.personID]?.score ?? -.infinity) {
                best[sample.personID] = (sampleID, score)
            }
        }
        return best
            .map { (personID: $0.key, sampleID: $0.value.sampleID, score: $0.value.score) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.personID < $1.personID }
    }

    /// The single sample with the highest cosine similarity to `embedding`;
    /// nil when `samples` is empty or every candidate is degenerate (a
    /// dimension mismatch or a zero/non-finite vector never matches).
    package static func nearestSample(embedding: [Float], samples: [VoiceSample]) -> VoiceSample? {
        samples
            .compactMap { sample -> (VoiceSample, Float)? in
                guard let score = cosine(embedding, sample.vector) else { return nil }
                return (sample, score)
            }
            .max { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The samples (active or pending, current model) the owner's naming of
    /// a voice as `confirmedPersonID` contradicts: another person's, scoring
    /// ≥ `importConflict` against `embedding` — owner anchors and auto
    /// samples included. The owner's newest explicit confirm wins for that
    /// voice (spec §5): a pending import left behind would re-raise the
    /// conflict in every later meeting, and an active sample of the other
    /// person would keep the two within the margin forever. `exemptPersonIDs`
    /// (the owner's own people) are never contradicted: a colleague's voice
    /// close to the owner's must not retire the owner's samples (invariant 2's
    /// spirit) — the margin rule keeps such a cluster unsure instead.
    package static func contradictingSamples(
        embedding: [Float],
        samples: [VoiceSample],
        confirmedPersonID: Int64,
        exemptPersonIDs: Set<Int64> = []
    ) -> [VoiceSample] {
        samples.filter { sample in
            (sample.status == .pending || sample.status == .active)
                && sample.modelVersion == VoiceRegistryPolicy.embeddingModelVersion
                && sample.personID != confirmedPersonID
                && !exemptPersonIDs.contains(sample.personID)
                && (cosine(embedding, sample.vector) ?? -1) >= VoiceRegistryPolicy.importConflict
        }
    }

    /// The confirmed person's own pending imported sample that claimed this
    /// voice (nearest, current model, ≥ `confident`) — the sample whose
    /// sender an import-confirm or conflict confirm of that person
    /// activates. nil when no import of theirs claimed it.
    package static func claimingPending(embedding: [Float], samples: [VoiceSample], personID: Int64) -> VoiceSample? {
        let own = samples.filter {
            $0.status == .pending && $0.personID == personID
                && $0.modelVersion == VoiceRegistryPolicy.embeddingModelVersion
        }
        guard let nearest = nearestSample(embedding: embedding, samples: own),
              (cosine(embedding, nearest.vector) ?? -1) >= VoiceRegistryPolicy.confident else { return nil }
        return nearest
    }

    /// True when a pending imported sample of a person OTHER than `personID`
    /// scores ≥ `importConflict` — an import claims this voice for someone
    /// else (spec §5; samples of one person from several senders agree, they
    /// merge by `person_key` into one person id).
    private static func disagrees(_ rankedPending: [(personID: Int64, sampleID: Int64, score: Float)],
                                  with personID: Int64) -> Bool {
        rankedPending.contains { $0.personID != personID && $0.score >= VoiceRegistryPolicy.importConflict }
    }

    /// One decision per cluster label. Bands (spec §2.2): a cluster with too
    /// little speech never matches; top ≥ confident (0.75 without an event)
    /// AND margin ≥ 0.10 AND invited (the owner always is) → confident;
    /// top ≥ confident but too close to the runner-up → conflict; a strong
    /// match on a non-invited person → unsure; a confident match that a
    /// pending imported sample of a DIFFERENT person also claims (≥
    /// `importConflict`) → conflict; a pending imported sample beating every
    /// active one → import confirmation (conflict when a pending sample of
    /// another person also claims it ≥ `importConflict`); top ≥ 0.55 → unsure;
    /// else unknown. A person is confidently assigned to at most one cluster
    /// per recording — the higher-scoring cluster keeps it, the other drops
    /// to unsure. A best match on a person the owner rejected for that
    /// cluster is never confident: at the confident bar it drops to unsure
    /// with no suggested person (a weaker, unsure-band match may still name
    /// them as a suggestion — suggestions never label).
    package static func decide(
        clusters: [Cluster],
        samples: [VoiceSample],
        invited: Set<Int64>?,
        ownerPersonIDs: Set<Int64>
    ) -> [String: Decision] {
        let usable = samples.filter { $0.modelVersion == VoiceRegistryPolicy.embeddingModelVersion }
        let active = usable.filter { $0.status == .active }
        let pending = usable.filter { $0.status == .pending }
        let threshold = invited == nil ? VoiceRegistryPolicy.confidentWithoutEvent : VoiceRegistryPolicy.confident
        var out: [String: Decision] = [:]
        var confidentByPerson: [Int64: (label: String, score: Float)] = [:]

        // Deterministic order: the one-cluster-per-person rule must not
        // depend on the caller's (often Dictionary-derived) ordering.
        for cluster in clusters.sorted(by: { $0.label < $1.label }) {
            guard cluster.speechSec >= VoiceRegistryPolicy.minClusterSpeechSec else {
                out[cluster.label] = .tooShort
                continue
            }
            let ranked = nearest(embedding: cluster.embedding, samples: active)
            let top = ranked.first
            let second = ranked.dropFirst().first?.score ?? -1
            let rankedPending = nearest(embedding: cluster.embedding, samples: pending)
            if let top, top.score >= threshold {
                if cluster.rejectedPersonIDs.contains(top.personID) {
                    // The owner said this cluster is not them — never
                    // assign them, and never let them claim their slot.
                    out[cluster.label] = .unsure(personID: nil, score: top.score, reason: .unsure)
                } else if top.score - second < VoiceRegistryPolicy.margin {
                    out[cluster.label] = .unsure(personID: top.personID, score: top.score, reason: .conflict)
                } else if disagrees(rankedPending, with: top.personID) {
                    // Spec §5: someone's file says this voice is a DIFFERENT
                    // person — ask instead of labeling silently.
                    out[cluster.label] = .unsure(personID: top.personID, score: top.score, reason: .conflict)
                } else if let invited, !invited.contains(top.personID), !ownerPersonIDs.contains(top.personID) {
                    out[cluster.label] = .unsure(personID: top.personID, score: top.score, reason: .unsure)
                } else if let prev = confidentByPerson[top.personID], prev.score >= top.score {
                    out[cluster.label] = .unsure(personID: top.personID, score: top.score, reason: .unsure)
                } else {
                    if let prev = confidentByPerson[top.personID] {
                        out[prev.label] = .unsure(personID: top.personID, score: prev.score, reason: .unsure)
                    }
                    out[cluster.label] = .confident(personID: top.personID, sampleID: top.sampleID, score: top.score)
                    confidentByPerson[top.personID] = (cluster.label, top.score)
                }
                continue
            }
            if let candidate = rankedPending.first,
               candidate.score >= threshold, candidate.score > (top?.score ?? -1) {
                // Two sources' files name this voice differently (spec §2.2/§5).
                let conflict = disagrees(rankedPending, with: candidate.personID)
                out[cluster.label] = .unsure(personID: candidate.personID, score: candidate.score,
                                             reason: conflict ? .conflict : .importConfirm)
                continue
            }
            if let top, top.score >= VoiceRegistryPolicy.unsureFloor {
                out[cluster.label] = .unsure(personID: top.personID, score: top.score, reason: .unsure)
            } else {
                out[cluster.label] = .unknown(bestScore: max(0, top?.score ?? 0))
            }
        }
        return out
    }
}
