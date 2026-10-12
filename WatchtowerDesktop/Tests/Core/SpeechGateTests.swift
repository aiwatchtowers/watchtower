import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

final class SpeechGateTests: XCTestCase {
    private let rate = 16_000

    private func sec(_ seconds: Double) -> Int { Int((seconds * Double(rate)).rounded()) }

    private func keeps(_ start: Double, _ end: Double, _ speech: [Range<Int>]) -> Bool {
        SpeechGate.keepsSegment(startSec: start, endSec: end, speech: speech, sampleRate: rate)
    }

    // MARK: L1

    func testWindowWithTwoTenthsOfASecondOfSpeechIsSilent() {
        XCTAssertTrue(SpeechGate.isSilent([], sampleRate: rate))
        XCTAssertTrue(SpeechGate.isSilent([sec(1)..<sec(1.2)], sampleRate: rate))
        XCTAssertTrue(SpeechGate.isSilent([sec(1)..<sec(1.1), sec(5)..<sec(5.1)], sampleRate: rate))
        XCTAssertFalse(SpeechGate.isSilent([sec(1)..<sec(1.3)], sampleRate: rate))
    }

    // MARK: L2

    func testSegmentEntirelyInAGapIsDropped() {
        let speech = [sec(0)..<sec(2), sec(10)..<sec(12)]
        XCTAssertFalse(keeps(4, 8, speech))
    }

    func testSegmentOverlappingAQuarterSecondIsKept() {
        // 0.25 s of a 5 s segment is only 5 %, but above the 0.2 s floor.
        XCTAssertTrue(keeps(1.75, 6.75, [sec(0)..<sec(2)]))
    }

    func testOneSecondSegmentOverlappingThirtyFivePercentIsKept() {
        XCTAssertTrue(keeps(1.65, 2.65, [sec(0)..<sec(2)]))
    }

    func testShortSegmentKeptByItsShareAlone() {
        // 0.12 s overlap is under the 0.2 s floor but 40 % of a 0.3 s segment.
        XCTAssertTrue(keeps(1.88, 2.18, [sec(0)..<sec(2)]))
        // 0.12 s of a 1 s segment: under both.
        XCTAssertFalse(keeps(1.88, 2.88, [sec(0)..<sec(2)]))
    }

    func testOverlapAddsUpAcrossRanges() {
        // 0.15 s + 0.15 s across two ranges of a 3 s segment = 0.3 s ≥ 0.2 s.
        XCTAssertTrue(keeps(1.85, 4.85, [sec(0)..<sec(2), sec(4.7)..<sec(6)]))
    }

    func testZeroLengthSegmentKeptOnlyInsideARange() {
        let speech = [sec(1)..<sec(2)]
        XCTAssertTrue(keeps(1.5, 1.5, speech))
        XCTAssertFalse(keeps(3, 3, speech))
    }

    func testMergedJoinsOverlappingAndTouchingRanges() {
        XCTAssertEqual(SpeechGate.merged([10..<20, 0..<5, 5..<8, 15..<30, 40..<50]), [0..<8, 10..<30, 40..<50])
    }

    // MARK: Energy fallback

    func testEnergyDetectorFindsNothingInZeros() {
        XCTAssertEqual(EnergySpeechDetector().speechRanges(in: SyntheticAudio.zeros(seconds: 5)), [])
        XCTAssertEqual(EnergySpeechDetector().speechRanges(in: []), [])
    }

    func testEnergyDetectorPadsAToneBurst() {
        let tone = SyntheticAudio.hum(seconds: 1, dBFS: -30, fundamental: 440)
        let samples = SyntheticAudio.zeros(seconds: 1) + tone + SyntheticAudio.zeros(seconds: 1)
        XCTAssertEqual(EnergySpeechDetector().speechRanges(in: samples), [sec(0.7)..<sec(2.3)])
    }

    func testEnergyDetectorIgnoresQuietNoise() {
        let detector = EnergySpeechDetector()
        XCTAssertEqual(detector.speechRanges(in: SyntheticAudio.whiteNoise(seconds: 5, dBFS: -60, seed: 1)), [])
        // Well above the floor, yet steady: noise does not rise above itself.
        XCTAssertEqual(detector.speechRanges(in: SyntheticAudio.whiteNoise(seconds: 5, dBFS: -45, seed: 2)), [])
        XCTAssertEqual(detector.speechRanges(in: SyntheticAudio.pinkNoise(seconds: 5, dBFS: -45, seed: 3)), [])
        XCTAssertEqual(detector.speechRanges(in: SyntheticAudio.hum(seconds: 5, dBFS: -40)), [])
    }

    func testEnergyDetectorFindsABurstOverNoise() {
        let noise = SyntheticAudio.whiteNoise(seconds: 3, dBFS: -45, seed: 4)
        var samples = noise
        let burst = SyntheticAudio.hum(seconds: 1, dBFS: -25, fundamental: 300)
        for index in burst.indices { samples[sec(1) + index] += burst[index] }
        XCTAssertEqual(EnergySpeechDetector().speechRanges(in: samples), [sec(0.7)..<sec(2.3)])
    }

    func testEnergyDetectorBridgesShortGapsAndDropsShortBursts() {
        let loud = SyntheticAudio.hum(seconds: 0.4, dBFS: -30, fundamental: 300)
        let blip = SyntheticAudio.hum(seconds: 0.1, dBFS: -30, fundamental: 300)
        let samples = SyntheticAudio.zeros(seconds: 1) + loud + SyntheticAudio.zeros(seconds: 0.3) + loud
            + SyntheticAudio.zeros(seconds: 2) + blip + SyntheticAudio.zeros(seconds: 1)
        // 1.0–1.4 and 1.7–2.1 join across the 0.3 s gap; the 0.1 s blip at 4.1 s is dropped.
        XCTAssertEqual(EnergySpeechDetector().speechRanges(in: samples), [sec(0.7)..<sec(2.4)])
    }
}
