import Foundation
import WatchtowerCore

/// What the registry loader hands the post-diarization pass: usable samples
/// (active + pending imported, current model), people by id, the event's
/// invited people (nil = ad-hoc, or an event with no human attendees — the
/// stricter no-event threshold applies) and the owner's people.
struct VoiceRegistrySnapshot: Sendable {
    let samples: [VoiceSample]
    let people: [Int64: VoicePrint]
    let invited: Set<Int64>?
    let ownerPersonIDs: Set<Int64>

    static let empty = Self(samples: [], people: [:], invited: nil, ownerPersonIDs: [])
}

/// What a saved recording leaves in the registry: label-queue tasks (keyed by
/// the cluster's final rendered label) and self-trained samples (their
/// `transcriptID` is filled by the writer once the save returns the id).
struct VoiceIdentificationOutcome: Sendable {
    let tasks: [(label: String, reason: VoiceLabelReason, personID: Int64?, score: Float?)]
    let autoSamples: [VoiceSample]

    var isEmpty: Bool { tasks.isEmpty && autoSamples.isEmpty }
}

extension MeetingRecorderCenter {
    /// `renderRoles`' result: the (role-tagged) text, its structured
    /// utterances, the per-cluster speakers payload, and the registry outcome.
    struct RenderedRoles {
        let text: String
        let utterances: [TranscriptUtterance]?
        let speakers: [SpeakerEmbedding]?
        let registry: VoiceIdentificationOutcome?
    }

    /// RoleAssigner inputs derived from the registry decisions, plus the
    /// decisions and snapshot the payload/outcome builders need.
    struct VoiceIdentification {
        let names: [String: String]
        /// Clusters confidently matched to an owner person. Non-nil ONLY when
        /// the owner holds a usable anchor (current model, this run's
        /// dimension) — an owner identity the registry cannot match must not
        /// arm the «Я» veto (semantics: `RoleAssigner.clusterLabels`' doc).
        let ownerClusters: Set<String>?
        /// Veto-suppression set: clusters ANY owner sample matches at ≥
        /// `confident`, even when someone else won. Conservative by owner
        /// decision — it protects a cluster from the veto, never promotes one
        /// to «Я».
        let ownerVoiceAlike: Set<String>
        let decisions: [String: VoiceMatcher.Decision]
        /// nil = the registry is off (toggle, no loader wired, or a failed read).
        let snapshot: VoiceRegistrySnapshot?

        static let off = Self(names: [:], ownerClusters: nil, ownerVoiceAlike: [], decisions: [:], snapshot: nil)
    }

    /// Registry identification (spec §2): nearest-sample decisions per
    /// cluster; only `.confident` ones become voice names.
    func identifyVoices(
        clusterEmbeddings: [String: [Float]],
        features: [String: ClusterFeatures],
        eventID: String?,
        config: TranscriptionConfig
    ) async -> VoiceIdentification {
        guard config.voiceRecognition, let registryLoader,
              let snapshot = await registryLoader(eventID) else { return .off }
        let clusters = clusterEmbeddings.map {
            VoiceMatcher.Cluster(label: $0.key, embedding: $0.value, speechSec: features[$0.key]?.speechSec ?? 0)
        }
        let decisions = VoiceMatcher.decide(clusters: clusters, samples: snapshot.samples, invited: snapshot.invited,
                                            ownerPersonIDs: snapshot.ownerPersonIDs)
        let ownerSamples = snapshot.samples.filter {
            snapshot.ownerPersonIDs.contains($0.personID) && $0.status == .active
                && $0.modelVersion == VoiceRegistryPolicy.embeddingModelVersion
        }
        // Armed = an owner anchor that could actually match SOME cluster of
        // this run (valid vector of a present dimension), checked against all
        // clusters — Dictionary order is seed-randomized.
        let dimensions = Set(clusterEmbeddings.values.map(\.count))
        let ownerArmed = ownerSamples.contains { $0.anchor && dimensions.contains($0.vector.count) }

        var names: [String: String] = [:]
        var owners: Set<String> = []
        var alike: Set<String> = []
        for (cluster, decision) in decisions {
            if case let .confident(personID, _, _) = decision, let person = snapshot.people[personID] {
                names[cluster] = person.displayName
                if snapshot.ownerPersonIDs.contains(personID) { owners.insert(cluster) }
            }
            if ownerArmed, let embedding = clusterEmbeddings[cluster],
               (VoiceMatcher.nearest(embedding: embedding, samples: ownerSamples).first?.score ?? -1)
                   >= VoiceRegistryPolicy.confident {
                alike.insert(cluster)
            }
        }
        return VoiceIdentification(names: names, ownerClusters: ownerArmed ? owners : nil,
                                   ownerVoiceAlike: alike, decisions: decisions, snapshot: snapshot)
    }

    /// The stable "Speaker N" each cluster restores to (`originalLabel`).
    /// An unnamed cluster keeps its rendered label; a named one («Я» or a
    /// voice name) gets the next number after every rendered "Speaker N", in
    /// first-appearance order — so no cluster's original label can ever
    /// collide with another cluster's current label in the same recording.
    static func originalLabels(labels: [String: String], speakers: [SpeakerSegment]) -> [String: String] {
        let used = labels.values.filter(SpeakerNaming.isUnnamed)
            .compactMap { Int($0.dropFirst("Speaker ".count)) }
        var next = (used.max() ?? 0) + 1
        var out: [String: String] = [:]
        for cluster in RoleAssigner.clusterOrder(speakers) {
            guard let label = labels[cluster] else { continue }
            if SpeakerNaming.isUnnamed(label) {
                out[cluster] = label
            } else {
                out[cluster] = "Speaker \(next)"
                next += 1
            }
        }
        return out
    }

    /// One `speakers_json` entry with its registry payload. `auto` only when
    /// the confident registry name is what actually rendered (a mega-cluster
    /// suppression or «Я» can override it); otherwise «Я»/a name is the role
    /// pass's (`owner`) and "Speaker N" is unlabeled (`none`).
    static func registryEntry(
        label: String,
        embedding: [Float],
        originalLabel: String?,
        features: ClusterFeatures?,
        decision: VoiceMatcher.Decision?,
        appliedName: String?
    ) -> SpeakerEmbedding {
        var entry = SpeakerEmbedding(speaker: label, embedding: embedding)
        entry.originalLabel = originalLabel
        entry.speechSec = features?.speechSec
        entry.channel = features?.channel
        entry.clips = features?.clips
        entry.modelVersion = VoiceRegistryPolicy.embeddingModelVersion
        if case let .confident(personID, sampleID, score) = decision, label == appliedName {
            entry.labelSource = .auto
            entry.personID = personID
            entry.matchedSampleID = sampleID
            entry.score = score
        } else {
            entry.labelSource = SpeakerNaming.isUnnamed(label) ? VoiceLabelSource.none : .owner
        }
        return entry
    }

    /// Queue tasks for unsure/unknown shipped clusters that have playable
    /// clips and are not «Я»; auto samples for confident clusters that pass
    /// the self-training rule and rendered as that person (or as «Я» for an
    /// owner match). An auto sample's `clusterLabel` is stamped with the
    /// cluster's STABLE `originalLabel` ("Speaker N"), never the rendered
    /// display name — the same convention `VoiceLabelingQueries.confirm`
    /// uses (`cluster.restoreLabel`) and rollback's `rejectAutoLabel` relies
    /// on to find the sample it minted (a rendered name isn't unique across
    /// runs and isn't what a later relabel restores to).
    static func registryOutcome(
        labels: [String: String],
        shipped: [String: [Float]],
        voiceNames: [String: String],
        decisions: [String: VoiceMatcher.Decision],
        features: [String: ClusterFeatures],
        originalLabels: [String: String],
        snapshot: VoiceRegistrySnapshot
    ) -> VoiceIdentificationOutcome {
        let active = snapshot.samples.filter {
            $0.status == .active && $0.modelVersion == VoiceRegistryPolicy.embeddingModelVersion
        }
        let anchors = active.filter(\.anchor)
        var tasks: [(label: String, reason: VoiceLabelReason, personID: Int64?, score: Float?)] = []
        var autoSamples: [VoiceSample] = []
        for (cluster, embedding) in shipped.sorted(by: { $0.key < $1.key }) {
            guard let label = labels[cluster], let decision = decisions[cluster] else { continue }
            let isSelf = label.caseInsensitiveCompare("Я") == .orderedSame
            let hasClips = !(features[cluster]?.clips.isEmpty ?? true)
            switch decision {
            case let .unsure(personID, score, reason) where !isSelf && hasClips:
                tasks.append((label, reason, personID, score))
            case let .unknown(bestScore) where !isSelf && hasClips:
                tasks.append((label, .unknown, nil, bestScore))
            case let .confident(personID, _, score):
                let rendered = label == voiceNames[cluster] || (isSelf && snapshot.ownerPersonIDs.contains(personID))
                let speech = features[cluster]?.speechSec ?? 0
                let runnerUp = VoiceMatcher.nearest(embedding: embedding, samples: active).dropFirst().first?.score ?? -1
                guard rendered, let normalized = VoiceMatcher.normalize(embedding),
                      VoiceLearning.shouldLearn(decision: decision, runnerUp: runnerUp, embedding: embedding,
                                                speechSec: speech, anchors: anchors) else { continue }
                autoSamples.append(VoiceSample(
                    personID: personID, embedding: VoicePrintEmbedding.encode(normalized),
                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .auto, anchor: false,
                    status: .active, clusterLabel: originalLabels[cluster] ?? label,
                    channel: features[cluster]?.channel ?? .unknown, score: score, speechSec: speech))
            default:
                continue
            }
        }
        return VoiceIdentificationOutcome(tasks: tasks, autoSamples: autoSamples)
    }
}
