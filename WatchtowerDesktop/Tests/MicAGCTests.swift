import XCTest
@testable import WatchtowerDesktop

final class MicAGCTests: XCTestCase {

    /// The measured defect: a 0.008-RMS mic under a 0.079-RMS system stream.
    private let quiet: Float = 0.008

    func testStartsAtUnityGain() {
        XCTAssertEqual(MicAGC().gain, 1)
    }

    func testQuietSpeechRampsTowardMaxGain() {
        var agc = MicAGC()
        for _ in 0..<200 { agc.update(cycleRMS: quiet) }
        // target / 0.008 = 6.25, clamped to maxGain.
        XCTAssertEqual(agc.gain, MicAGC.maxGain, accuracy: 0.01)
    }

    func testGainNeverExceedsMaxGain() {
        var agc = MicAGC()
        // Barely above the noise floor: an unclamped desired gain would be ~24x.
        for _ in 0..<10_000 { agc.update(cycleRMS: MicAGC.noiseFloor * 1.05) }
        XCTAssertLessThanOrEqual(agc.gain, MicAGC.maxGain)
    }

    func testFirstSpeechCycleSeedsEMAWithoutColdStartSpike() {
        var agc = MicAGC()
        agc.update(cycleRMS: quiet)
        // Seeded at 0.008 (not at 0), so the very first step is one ordinary
        // 5% approach toward the clamped desired gain, not a jump to the cap.
        XCTAssertEqual(agc.gain, 1 + (MicAGC.maxGain - 1) * 0.05, accuracy: 0.0001)
    }

    func testHealthyMicStaysAtUnityGain() {
        var agc = MicAGC()
        for _ in 0..<200 { agc.update(cycleRMS: MicAGC.target) }
        XCTAssertEqual(agc.gain, 1, accuracy: 0.0001)
    }

    func testLoudMicIsNeverAttenuated() {
        var agc = MicAGC()
        for _ in 0..<200 { agc.update(cycleRMS: 0.5) }
        XCTAssertEqual(agc.gain, 1, accuracy: 0.0001, "AGC only boosts, never attenuates")
    }

    func testSilenceLeavesGainUnchangedInBothDirections() {
        var cold = MicAGC()
        for _ in 0..<100 { cold.update(cycleRMS: MicAGC.noiseFloor * 0.5) }
        XCTAssertEqual(cold.gain, 1, "silence must not ramp the gain up")

        var warm = MicAGC()
        for _ in 0..<200 { warm.update(cycleRMS: quiet) }
        let ramped = warm.gain
        for _ in 0..<500 { warm.update(cycleRMS: 0) }
        XCTAssertEqual(warm.gain, ramped, "silence must not decay the gain either")
    }

    func testBacksOffFasterThanItRampsUp() {
        var up = MicAGC()
        up.update(cycleRMS: quiet)
        let rampStep = up.gain - 1

        var down = MicAGC()
        for _ in 0..<200 { down.update(cycleRMS: quiet) }
        let beforeBackoff = down.gain
        down.update(cycleRMS: 0.2) // someone leaned into the mic
        let backoffStep = beforeBackoff - down.gain

        XCTAssertGreaterThan(backoffStep, 0, "a loud cycle must reduce the gain")
        XCTAssertGreaterThan(backoffStep, rampStep, "back-off is faster than ramp-up")
    }

    func testGainNeverDropsBelowUnity() {
        var agc = MicAGC()
        for _ in 0..<200 { agc.update(cycleRMS: quiet) }
        for _ in 0..<1_000 { agc.update(cycleRMS: 1.0) }
        XCTAssertGreaterThanOrEqual(agc.gain, 1)
    }
}
