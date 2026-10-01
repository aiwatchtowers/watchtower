import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class ClusterFeaturesTests: XCTestCase {
    private func seg(_ id: String, _ a: Double, _ b: Double) -> SpeakerSegment {
        SpeakerSegment(speakerID: id, startSec: a, endSec: b, embedding: nil)
    }

    private func activity(seconds: Int, mic: Float, sys: Float) -> MicActivity {
        MicActivity(bins: Array(repeating: .init(mic: mic, sys: sys), count: seconds * 10))
    }

    func testSpeechAndClipsPickLongestTrimmedSegments() throws {
        let f = try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 0, 3), seg("A", 10, 30), seg("A", 40, 46), seg("A", 50, 55)], activity: nil)["A"])
        XCTAssertEqual(f.speechSec, 3 + 20 + 6 + 5, accuracy: 0.01)
        XCTAssertEqual(f.clips.count, 3)
        XCTAssertEqual(f.clips.first, ClipSpan(start: 10.3, end: 16.3))            // trimmed 0.3 s, capped at 6 s
        XCTAssertFalse(f.clips.contains { $0.end - $0.start < VoiceRegistryPolicy.clipMinSec })
        XCTAssertEqual(f.channel, .unknown)
    }

    func testChannelFromActivity() throws {
        XCTAssertEqual(try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 0, 30)], activity: activity(seconds: 30, mic: 0.001, sys: 0.05))["A"]).channel, .remote)
        XCTAssertEqual(try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 0, 30)], activity: activity(seconds: 30, mic: 0.05, sys: 0.0))["A"]).channel, .room)
        // Every bin ambiguous (near-equal levels) → no vote → unknown.
        XCTAssertEqual(try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 0, 30)], activity: activity(seconds: 30, mic: 0.05, sys: 0.04))["A"]).channel, .unknown)
    }

    func testShortSegmentsYieldNoClipsAndClustersAreSeparate() {
        let features = ClusterFeatures.compute(speakers: [seg("A", 0, 4.5), seg("B", 5, 20)], activity: nil)
        XCTAssertEqual(features["A"]?.clips, [], "4.5 s trims to 3.9 s — below the clip minimum")
        XCTAssertEqual(features["B"]?.clips, [ClipSpan(start: 5.3, end: 11.3)])
        XCTAssertEqual(features["B"]?.speechSec ?? 0, 15, accuracy: 0.001)
    }

    // The diarizer cuts a long turn at its 10 s chunk boundaries; those
    // slices are one speech run, so they yield one clip, not three
    // back-to-back pieces of the same sentence.
    func testChunkSlicesOfOneTurnYieldOneClip() throws {
        let f = try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 100, 109.6), seg("A", 109.6, 119.6), seg("A", 119.6, 129.6)], activity: nil)["A"])
        XCTAssertEqual(f.clips, [ClipSpan(start: 100.3, end: 106.3)])
    }

    // Clips come from different parts of the meeting before a second clip
    // is taken from near an earlier one, and are listed in time order.
    func testClipsSpreadAcrossTheMeetingInTimeOrder() throws {
        let f = try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 0, 20), seg("A", 25, 44), seg("A", 30 * 60, 30 * 60 + 8), seg("A", 50 * 60, 50 * 60 + 6)],
            activity: nil)["A"])
        XCTAssertEqual(f.clips.map(\.start), [0.3, 30 * 60 + 0.3, 50 * 60 + 0.3])
        XCTAssertTrue(f.clips.allSatisfy { $0.end - $0.start <= VoiceRegistryPolicy.clipMaxSec + 1e-9 })
    }

    // Degenerate: fewer far-apart runs than clips — the rest are topped up
    // from the next longest runs rather than leaving the card short.
    func testTopsUpFromNearbyRunsWhenTooFewAreFarApart() throws {
        let f = try XCTUnwrap(ClusterFeatures.compute(
            speakers: [seg("A", 0, 20), seg("A", 25, 44), seg("A", 50, 58)], activity: nil)["A"])
        XCTAssertEqual(f.clips.map(\.start), [0.3, 25.3, 50.3])
    }
}
