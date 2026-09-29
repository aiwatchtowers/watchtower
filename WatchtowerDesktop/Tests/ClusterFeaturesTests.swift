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
        XCTAssertEqual(f.clips.first, ClipSpan(start: 10.3, end: 20.3))            // trimmed 0.3 s, capped at 10 s
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
        XCTAssertEqual(features["B"]?.clips, [ClipSpan(start: 5.3, end: 15.3)])
        XCTAssertEqual(features["B"]?.speechSec ?? 0, 15, accuracy: 0.001)
    }
}
