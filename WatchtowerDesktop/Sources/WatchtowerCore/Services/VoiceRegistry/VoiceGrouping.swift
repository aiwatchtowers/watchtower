/// One recording's unrecognized voice, as fed into `VoiceGrouping` (spec
/// §4.2, the Train screen's cross-meeting bulk labeling — the research
/// spike). Carries just enough to group and to render a card: no DB access,
/// no file I/O.
package struct GroupableCluster: Equatable, Sendable {
    /// `"<transcriptID>:<label>"` — unique across every recording, since a
    /// transcript never carries two clusters with the same rendered label.
    package let key: String
    package let transcriptID: Int64
    package let label: String
    package let embedding: [Float]
    package let speechSec: Double
    /// Whether the recording this cluster came from still has its audio file
    /// on disk — a group needs at least one audio member to be labelable.
    package let hasAudio: Bool
    /// Person keys of this cluster's meeting's invited attendees (the
    /// `VoiceRegistryCenter.PersonChoice.personKey` normalization), used only
    /// for the "not-yet-registered attendee" suggestion.
    package let attendees: Set<String>

    package init(
        key: String,
        transcriptID: Int64,
        label: String,
        embedding: [Float],
        speechSec: Double,
        hasAudio: Bool,
        attendees: Set<String>
    ) {
        self.key = key
        self.transcriptID = transcriptID
        self.label = label
        self.embedding = embedding
        self.speechSec = speechSec
        self.hasAudio = hasAudio
        self.attendees = attendees
    }
}

/// Pure cross-meeting voice grouping (spec §4.2). No I/O — every cluster and
/// sample is passed in, so this is directly unit-testable against fixtures
/// shaped like the research spike's.
package enum VoiceGrouping {
    /// Average-linkage agglomerative clustering: repeatedly merges the pair
    /// of groups with the highest mean pairwise cosine, as long as it clears
    /// `mergeAt` — EXCEPT a pair that would put two clusters of the same
    /// recording into one group (cannot-link). The cannot-link flag is
    /// OR-ed on every merge, so it holds no matter how many merges already
    /// happened — two clusters of one recording can never end up in the same
    /// group transitively either. Groups are returned sorted by total speech,
    /// descending (spec §4.2 step 4: cards ordered by speech).
    ///
    /// Cost bound: every cosine is computed ONCE, into an n×n matrix of
    /// cross-pair sums/counts (O(n²·d) up front, O(n²) memory); a merge then
    /// updates the merged group's row Lance-Williams style (sums and counts
    /// add, so the mean stays the exact average linkage) in O(n), and each
    /// merge step's best-pair scan is O(n²) of plain arithmetic — O(n³)
    /// additions overall, no vector work. The caller also caps n
    /// (`VoiceRegistryPolicy.trainCandidateCap`), since Train regroups live
    /// after every confirm.
    package static func group(_ clusters: [GroupableCluster], mergeAt: Float = VoiceRegistryPolicy.groupMerge) -> [[GroupableCluster]] {
        let n = clusters.count
        guard n > 1 else { return clusters.map { [$0] } }
        var links = LinkageMatrix(clusters)
        var members: [[Int]] = (0..<n).map { [$0] }
        var alive = [Bool](repeating: true, count: n)

        while true {
            var bestPair: (Int, Int)?
            var bestScore = -Float.infinity
            for i in 0..<n where alive[i] {
                for j in (i + 1)..<n where alive[j] {
                    guard let score = links.averageLinkage(i, j) else { continue }
                    if score > bestScore {
                        bestScore = score
                        bestPair = (i, j)
                    }
                }
            }
            guard let (i, j) = bestPair, bestScore >= mergeAt else { break }
            members[i] += members[j]
            alive[j] = false
            links.mergeCluster(j, into: i, alive: alive)
        }
        return (0..<n).filter { alive[$0] }
            .map { members[$0].map { clusters[$0] } }
            .sorted { totalSpeech($0) > totalSpeech($1) }
    }

    /// Cross-pair cosine sums and valid-pair counts between groups, indexed
    /// by each group's first cluster; a pair of degenerate vectors
    /// (dimension mismatch, zero/non-finite) never counts — the mean is over
    /// valid pairs only, nil when there are none.
    private struct LinkageMatrix {
        let n: Int
        var sum: [Float]
        var count: [Int]
        var cannotLink: [Bool]

        init(_ clusters: [GroupableCluster]) {
            n = clusters.count
            sum = [Float](repeating: 0, count: n * n)
            count = [Int](repeating: 0, count: n * n)
            cannotLink = [Bool](repeating: false, count: n * n)
            let vectors = clusters.map { VoiceMatcher.normalize($0.embedding) }
            for i in 0..<n {
                for j in (i + 1)..<n {
                    if clusters[i].transcriptID == clusters[j].transcriptID {
                        cannotLink[i * n + j] = true
                        cannotLink[j * n + i] = true
                    }
                    guard let a = vectors[i], let b = vectors[j], a.count == b.count else { continue }
                    let cosine = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    sum[i * n + j] = cosine
                    sum[j * n + i] = cosine
                    count[i * n + j] = 1
                    count[j * n + i] = 1
                }
            }
        }

        func averageLinkage(_ i: Int, _ j: Int) -> Float? {
            let k = i * n + j
            guard !cannotLink[k], count[k] > 0 else { return nil }
            return sum[k] / Float(count[k])
        }

        mutating func mergeCluster(_ j: Int, into i: Int, alive: [Bool]) {
            for k in 0..<n where alive[k] && k != i {
                sum[i * n + k] += sum[j * n + k]
                sum[k * n + i] = sum[i * n + k]
                count[i * n + k] += count[j * n + k]
                count[k * n + i] = count[i * n + k]
                cannotLink[i * n + k] = cannotLink[i * n + k] || cannotLink[j * n + k]
                cannotLink[k * n + i] = cannotLink[i * n + k]
            }
        }
    }

    /// The not-yet-registered attendee present at the most of the group's
    /// distinct meetings (spec §4.2 step 3's invite intersection — no AI).
    /// nil when the group has no attendee outside `registeredKeys`.
    package static func suggestion(for group: [GroupableCluster], registeredKeys: Set<String>) -> (personKey: String, meetings: Int, of: Int)? {
        let totalMeetings = Set(group.map(\.transcriptID)).count
        var counts: [String: Int] = [:]
        for member in group {
            for key in member.attendees where !registeredKeys.contains(key) {
                counts[key, default: 0] += 1
            }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let best = ranked.first else { return nil }
        return (personKey: best.key, meetings: best.value, of: totalMeetings)
    }

    /// Leave-one-recording-out precision/recall of `threshold` against the
    /// owner's own anchors: for each anchor tied to a recording, match it
    /// against every OTHER recording's anchors only (never its own — an
    /// anchor must not be allowed to vouch for itself) and check whether the
    /// nearest-with-margin match names the right person. Only anchors whose
    /// person has anchors elsewhere are evaluated (`evaluated`) — one with
    /// none could never be found regardless of the threshold, so counting it
    /// would only pad the sample size without measuring anything.
    package static func estimateAccuracy(
        anchors: [VoiceSample], threshold: Float = VoiceRegistryPolicy.confident
    ) -> (precision: Double, recall: Double, evaluated: Int) {
        let candidates = anchors.filter { $0.transcriptID != nil }
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        for anchor in candidates {
            let recordingID = anchor.transcriptID
            let prints = candidates.filter { $0.transcriptID != recordingID }
            guard prints.contains(where: { $0.personID == anchor.personID }) else { continue }

            let ranked = VoiceMatcher.nearest(embedding: anchor.vector, samples: prints)
            let top = ranked.first
            let runnerUp = ranked.dropFirst().first?.score ?? -1
            if let top, top.score >= threshold, top.score - runnerUp >= VoiceRegistryPolicy.margin {
                if top.personID == anchor.personID { truePositives += 1 } else { falsePositives += 1 }
            } else {
                falseNegatives += 1
            }
        }
        let evaluated = truePositives + falsePositives + falseNegatives
        let precision = truePositives + falsePositives > 0 ? Double(truePositives) / Double(truePositives + falsePositives) : 1
        let recall = truePositives + falseNegatives > 0 ? Double(truePositives) / Double(truePositives + falseNegatives) : 1
        return (precision, recall, evaluated)
    }

    private static func totalSpeech(_ group: [GroupableCluster]) -> Double {
        group.reduce(0) { $0 + $1.speechSec }
    }
}
