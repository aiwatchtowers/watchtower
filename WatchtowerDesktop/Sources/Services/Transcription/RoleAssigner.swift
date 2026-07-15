import Foundation

/// Pure mapping of a diarized speaker timeline onto timestamped transcript
/// segments, plus rendering of the final role-tagged text. No I/O.
enum RoleAssigner {
    static let selfLabel = "Я"
    /// Mic RMS must exceed system RMS by this factor for a bin to read as
    /// "the owner is speaking" (the mic channel leaks meeting audio quietly).
    static let micDominanceFactor: Float = 2.0
    /// Minimum share of a cluster's speech bins with mic dominance for the
    /// cluster to be labelled as the owner.
    static let selfShareThreshold = 0.6

    /// nil when roles cannot be derived (no segments / no speakers) — the
    /// caller then keeps the plain transcript text.
    static func render(
        segments: [TranscriptSegment],
        speakers: [SpeakerSegment],
        activity: MicActivity?
    ) -> String? {
        guard !segments.isEmpty, !speakers.isEmpty else { return nil }

        // Cluster order by first appearance drives Speaker 1..N numbering.
        var clusterOrder: [String] = []
        for s in speakers.sorted(by: { $0.startSec < $1.startSec }) where !clusterOrder.contains(s.speakerID) {
            clusterOrder.append(s.speakerID)
        }

        // 1. Each transcript segment → cluster with the largest temporal
        //    overlap; no overlap → the previous segment's cluster.
        var assigned: [(segment: TranscriptSegment, cluster: String)] = []
        var previous = clusterOrder[0]
        for segment in segments {
            var best: (id: String, overlap: Double)?
            for s in speakers {
                let overlap = min(segment.endSec, s.endSec) - max(segment.startSec, s.startSec)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (s.speakerID, overlap)
                }
            }
            let cluster = best?.id ?? previous
            assigned.append((segment, cluster))
            previous = cluster
        }

        // 2. Labels: the mic-dominated cluster is «Я», the rest are numbered.
        let selfCluster = detectSelfCluster(speakers: speakers, activity: activity)
        var labels: [String: String] = [:]
        var counter = 0
        for id in clusterOrder {
            if id == selfCluster {
                labels[id] = selfLabel
            } else {
                counter += 1
                labels[id] = "Speaker \(counter)"
            }
        }

        // 3. Merge consecutive same-cluster segments into one paragraph.
        var lines: [String] = []
        var currentCluster: String?
        var currentTexts: [String] = []
        func flush() {
            guard let cluster = currentCluster, !currentTexts.isEmpty else { return }
            lines.append("[\(labels[cluster] ?? cluster)] " + currentTexts.joined(separator: " "))
        }
        for (segment, cluster) in assigned {
            if cluster != currentCluster {
                flush()
                currentCluster = cluster
                currentTexts = []
            }
            currentTexts.append(segment.text)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// The cluster whose speech time is dominated by the mic channel — the
    /// machine's owner. nil without an activity sidecar or when no cluster
    /// clears the threshold (then every speaker stays a numbered stranger).
    /// Ties break toward the earliest-appearing cluster for determinism.
    private static func detectSelfCluster(speakers: [SpeakerSegment], activity: MicActivity?) -> String? {
        guard let activity else { return nil }
        var stats: [String: (dominated: Int, total: Int)] = [:]
        var order: [String] = []
        for s in speakers.sorted(by: { $0.startSec < $1.startSec }) {
            if !order.contains(s.speakerID) { order.append(s.speakerID) }
            var t = s.startSec
            while t < s.endSec {
                if let bin = activity.bin(at: t) {
                    var entry = stats[s.speakerID] ?? (0, 0)
                    entry.total += 1
                    if bin.mic > bin.sys * micDominanceFactor {
                        entry.dominated += 1
                    }
                    stats[s.speakerID] = entry
                }
                t += MicActivity.binDuration
            }
        }
        var best: (id: String, share: Double)?
        for id in order {
            guard let entry = stats[id], entry.total > 0 else { continue }
            let share = Double(entry.dominated) / Double(entry.total)
            if share > (best?.share ?? 0) { best = (id, share) } // strict >: earliest wins ties
        }
        guard let best, best.share > selfShareThreshold else { return nil }
        return best.id
    }
}
