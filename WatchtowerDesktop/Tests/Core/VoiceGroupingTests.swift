import XCTest
@testable import WatchtowerCore

/// `VoiceGrouping` (spec §4.2): cross-meeting voice grouping for the Train
/// screen, plus its suggestion heuristic and threshold accuracy estimate.
final class VoiceGroupingTests: XCTestCase {
    private func c(_ key: String, tid: Int64, _ v: [Float], speech: Double = 60, audio: Bool = true, att: Set<String> = []) -> GroupableCluster {
        GroupableCluster(key: key, transcriptID: tid, label: key, embedding: v, speechSec: speech, hasAudio: audio, attendees: att)
    }

    func testSameRecordingNeverMerges() {
        let g = VoiceGrouping.group([c("a", tid: 1, [1, 0]), c("b", tid: 1, [1, 0])])
        XCTAssertEqual(g.count, 2)
    }

    func testSimilarAcrossRecordingsMergeAndSortBySpeech() {
        // swiftlint:disable:next line_length
        let g = VoiceGrouping.group([c("a", tid: 1, [1, 0], speech: 30), c("b", tid: 2, [0.99, 0.1], speech: 30), c("z", tid: 3, [0, 1], speech: 100)])
        XCTAssertEqual(g.map { $0.map(\.key).sorted() }, [["z"], ["a", "b"]])
    }

    func testSuggestionUsesInviteIntersectionExcludingRegistered() {
        let group = [c("a", tid: 1, [1, 0], att: ["alice@example.com", "bob@example.com"]), c("b", tid: 2, [1, 0], att: ["alice@example.com"])]
        XCTAssertEqual(VoiceGrouping.suggestion(for: group, registeredKeys: [])?.personKey, "alice@example.com")
        XCTAssertEqual(VoiceGrouping.suggestion(for: group, registeredKeys: ["alice@example.com"])?.personKey, "bob@example.com")
    }

    func testAccuracyEstimateLeaveOneRecordingOut() {
        func a(_ id: Int64, _ p: Int64, _ tid: Int64, _ v: [Float]) -> VoiceSample {
            VoiceSample(id: id, personID: p, embedding: VoicePrintEmbedding.encode(v), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                        origin: .owner, anchor: true, status: .active, transcriptID: tid)
        }
        let r = VoiceGrouping.estimateAccuracy(anchors: [a(1, 1, 1, [1, 0]), a(2, 1, 2, [0.98, 0.1]), a(3, 2, 1, [0, 1]), a(4, 2, 3, [0.1, 0.99])])
        XCTAssertEqual(r.precision, 1); XCTAssertEqual(r.recall, 1); XCTAssertEqual(r.evaluated, 4)
    }

    /// The matrix/Lance-Williams implementation must group exactly like the
    /// naive recompute-every-pair average linkage it replaced.
    func testMatrixGroupingMatchesNaiveAverageLinkage() {
        var seed: UInt64 = 42
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) - 0.5
        }
        // Five hidden voices, 60 clusters over 20 recordings, noisy copies.
        let voices = (0..<5).map { _ in (0..<8).map { _ in next() } }
        let clusters = (0..<60).map { i -> GroupableCluster in
            let voice = voices[i % 5]
            return c("k\(i)", tid: Int64(i % 20), voice.map { $0 + next() * 0.3 }, speech: Double(i))
        }
        func keys(_ groups: [[GroupableCluster]]) -> Set<Set<String>> { Set(groups.map { Set($0.map(\.key)) }) }
        let grouped = VoiceGrouping.group(clusters)
        XCTAssertTrue((2..<30).contains(grouped.count), "the fixture must actually merge (got \(grouped.count) groups)")
        XCTAssertEqual(keys(grouped), keys(naiveGroup(clusters, mergeAt: VoiceRegistryPolicy.groupMerge)))
    }

    private func naiveGroup(_ clusters: [GroupableCluster], mergeAt: Float) -> [[GroupableCluster]] {
        var groups = clusters.map { [$0] }
        while groups.count > 1 {
            var best: (Int, Int)?
            var bestScore = -Float.infinity
            for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let ids = Set(groups[i].map(\.transcriptID))
                    guard !groups[j].contains(where: { ids.contains($0.transcriptID) }) else { continue }
                    let pairs = groups[i].flatMap { x in groups[j].compactMap { VoiceMatcher.cosine(x.embedding, $0.embedding) } }
                    guard !pairs.isEmpty else { continue }
                    let score = pairs.reduce(0, +) / Float(pairs.count)
                    if score > bestScore { bestScore = score; best = (i, j) }
                }
            }
            guard let (i, j) = best, bestScore >= mergeAt else { break }
            let merged = groups[i] + groups[j]
            groups.remove(at: j)
            groups.remove(at: i)
            groups.append(merged)
        }
        return groups
    }
}
