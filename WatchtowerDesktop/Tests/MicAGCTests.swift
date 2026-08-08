import XCTest
@testable import WatchtowerDesktop

final class MicAGCTests: XCTestCase {

    /// A 512-frame IO cycle at 48 kHz — the realistic step the recorder feeds.
    private let cycle: TimeInterval = 512.0 / 48_000.0
    /// The measured defect: the owner's mic at ~0.008 RMS.
    private let quiet: Float = 0.008
    /// Quiet enough that the owner still dominates it by more than 2x.
    private let silentSystem: Float = 0.001

    /// Runs `count` cycles of the same RMS pair.
    private func feed(_ agc: inout MicAGC, mic: Float, system: Float, count: Int) {
        for _ in 0..<count {
            agc.update(cycleRMS: mic, systemRMS: system, cycleDuration: cycle)
        }
    }

    /// 20 s of audio — ten time constants, so both the EMA and the gain have
    /// settled to well inside the accuracy the assertions below use.
    private var cyclesToConverge: Int { Int(20 / cycle) }

    // MARK: Gain law

    func testStartsAtUnityGain() {
        let agc = MicAGC()
        XCTAssertEqual(agc.speechGain, 1)
        XCTAssertEqual(agc.appliedGain, 1)
    }

    func testQuietOwnerSpeechRampsTowardMaxGain() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        // target / 0.008 = 6.25, clamped to maxGain.
        XCTAssertEqual(agc.appliedGain, MicAGC.maxGain, accuracy: 0.01)
    }

    func testMidRangeSpeechConvergesToTheProportionalGain() {
        var agc = MicAGC()
        // 0.02 sits between the clamp endpoints: the law must land on
        // target / 0.02 = 2.5, not on 1 and not on maxGain.
        feed(&agc, mic: 0.02, system: silentSystem, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, 2.5, accuracy: 0.01)
    }

    func testConvergesProportionallyInTheMeasuredOperatingBand() {
        var agc = MicAGC()
        // 0.0125 is where the real recording's own speech actually sits, and
        // it is still inside the proportional region: target / 0.0125 = 4.
        feed(&agc, mic: 0.0125, system: silentSystem, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, 4, accuracy: 0.01)
    }

    func testConvergedGainDoesNotDependOnTheIOBufferSize() {
        // Same 20 s of the same speech, delivered as small and large buffers.
        var small = MicAGC()
        let smallCycle = 256.0 / 48_000.0
        for _ in 0..<Int(20 / smallCycle) {
            small.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: smallCycle)
        }

        var large = MicAGC()
        let largeCycle = 2048.0 / 48_000.0
        for _ in 0..<Int(20 / largeCycle) {
            large.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: largeCycle)
        }

        XCTAssertEqual(small.appliedGain, large.appliedGain, accuracy: 0.05,
                       "wall-clock time constants, not per-callback ones")
    }

    // MARK: Glide

    func testGlideStartsAtTheCurrentGainAndStepsToTheTarget() {
        let (start, step) = MicAGC.glide(from: 2, to: 5, frameCount: 3)
        XCTAssertEqual(start, 2)
        XCTAssertEqual(step, 1)
    }

    func testGlideBetweenEqualGainsHasNoStep() {
        let (start, step) = MicAGC.glide(from: 1, to: 1, frameCount: 512)
        XCTAssertEqual(start, 1)
        XCTAssertEqual(step, 0)
        XCTAssertFalse(step.sign == .minus, "an off-gate cycle adds +0.0, leaving the mix untouched")
    }

    func testGainNeverExceedsMaxGain() {
        var agc = MicAGC()
        // Just over the floor: an unclamped desired gain would be ~8x.
        feed(&agc, mic: MicAGC.noiseFloor * 1.05, system: 0, count: 10_000)
        XCTAssertLessThanOrEqual(agc.appliedGain, MicAGC.maxGain)
    }

    func testGainNeverDropsBelowUnity() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        feed(&agc, mic: 1.0, system: 0, count: cyclesToConverge)
        XCTAssertGreaterThanOrEqual(agc.appliedGain, 1)
    }

    func testFirstSpeechCycleSeedsEMAWithoutColdStartSpike() {
        var agc = MicAGC()
        agc.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: cycle)
        // Seeded at 0.008 (not at 0), so the first step is one ordinary
        // ramp-up approach toward the clamped desired gain, not a jump to the cap.
        let step = Float(1 - exp(-cycle / MicAGC.rampUpTau))
        XCTAssertEqual(agc.speechGain, 1 + (MicAGC.maxGain - 1) * step, accuracy: 0.0001)
    }

    func testHealthyMicStaysAtUnityGain() {
        var agc = MicAGC()
        feed(&agc, mic: MicAGC.target, system: silentSystem, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, 1, accuracy: 0.0001)
    }

    func testLoudMicIsClampedToUnityNotAttenuated() {
        var agc = MicAGC()
        feed(&agc, mic: 0.5, system: 0, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, 1, accuracy: 0.0001,
                       "a mic above target is left alone at 1, never scaled down")
    }

    func testBacksOffFasterThanItRampsUp() {
        // Both steps below close the same ~5-unit gap between the current gain
        // and the one the level asks for, so their sizes compare directly.
        var up = MicAGC()
        up.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: cycle)
        let rampStep = up.speechGain - 1

        var down = MicAGC()
        feed(&down, mic: quiet, system: silentSystem, count: cyclesToConverge)
        let beforeBackoff = down.speechGain
        // Loud enough that this one cycle drags the EMA above `target`, which
        // pins the asked-for gain at 1 — someone leaning into the mic.
        down.update(cycleRMS: 10, systemRMS: 0, cycleDuration: cycle)
        let backoffStep = beforeBackoff - down.speechGain

        XCTAssertGreaterThan(backoffStep, 0, "a loud cycle must reduce the gain")
        XCTAssertGreaterThan(backoffStep, rampStep * 5,
                             "back-off covers the same gap far faster than ramp-up (tau 0.2 s vs 2 s)")
    }

    func testRecoversFromASingleLoudTransient() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        let beforeTransient = agc.speechGain
        agc.update(cycleRMS: 0.4, systemRMS: 0, cycleDuration: cycle)
        XCTAssertLessThan(agc.speechGain, beforeTransient - 0.01, "the outlier pulled the gain down")
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, MicAGC.maxGain, accuracy: 0.01,
                       "quiet speech re-converges after the transient")
    }

    // MARK: Dominance gate

    func testRemoteAudioBleedIsNeverBoosted() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        let ramped = agc.speechGain

        // Measured bleed: mic 0.013 under a loud system stream — louder than
        // the owner's own speech in absolute terms, but not dominant.
        feed(&agc, mic: 0.013, system: 0.079, count: 500)
        XCTAssertEqual(agc.appliedGain, 1, "bleed cycles are mixed at unity gain")
        XCTAssertEqual(agc.speechGain, ramped, "bleed must not move the speech state")
    }

    func testGainResumesAfterBleedWithoutReseeding() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        let ramped = agc.speechGain

        // Clearly system-dominant, so the hold is cancelled and the mix drops
        // to unity at once.
        feed(&agc, mic: 0.013, system: 0.079, count: 500)
        XCTAssertEqual(agc.appliedGain, 1)

        // The owner speaking again picks the held gain straight back up
        // instead of ramping from 1.
        agc.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: cycle)
        XCTAssertEqual(agc.appliedGain, agc.speechGain)
        XCTAssertEqual(agc.appliedGain, ramped, accuracy: 0.01,
                       "the owner's next word resumes at the ramped gain")
    }

    // MARK: Hold (apply-gate vs adapt-gate)

    func testGainHoldsThroughAnIntraPhraseGap() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: 20)
        let speaking = agc.appliedGain

        // ~32 ms of a consonant/breath gap: below the floor, but nowhere near
        // system-dominant. The owner is still mid-phrase.
        for _ in 0..<3 {
            agc.update(cycleRMS: 0.004, systemRMS: 0, cycleDuration: cycle)
            XCTAssertEqual(agc.appliedGain, agc.speechGain,
                           "the gap must not drop the mix to unity mid-phrase")
        }
        XCTAssertEqual(agc.appliedGain, speaking, accuracy: 0.0001)

        agc.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: cycle)
        XCTAssertEqual(agc.appliedGain, agc.speechGain)
    }

    func testHoldExpiresAfterHoldSec() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        let ramped = agc.speechGain

        let cyclesPastHold = Int(MicAGC.holdSec / cycle) + 5
        feed(&agc, mic: 0.004, system: 0, count: cyclesPastHold)

        XCTAssertEqual(agc.appliedGain, 1, "the hold runs out on a long silence")
        XCTAssertEqual(agc.speechGain, ramped, "but the learned speech level survives it")
    }

    func testClearBleedReleasesTheHoldImmediately() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: 20)
        XCTAssertGreaterThan(agc.appliedGain, 1)

        // One unambiguous remote-audio cycle, well inside the hold window.
        agc.update(cycleRMS: 0.013, systemRMS: 0.079, cycleDuration: cycle)
        XCTAssertEqual(agc.appliedGain, 1, "bleed cancels the hold rather than coasting through it")
    }

    func testDominanceChatterDoesNotModulateTheGain() {
        var agc = MicAGC()
        feed(&agc, mic: quiet, system: silentSystem, count: 20)

        // Alternating either side of the 2x dominance line with a quiet system
        // channel — the syllable-rate flicker that made the per-cycle switch
        // amplitude-modulate the owner's own speech.
        let system: Float = 0.005
        for i in 0..<200 {
            let mic: Float = i.isMultiple(of: 2) ? 0.0102 : 0.0098
            agc.update(cycleRMS: mic, systemRMS: system, cycleDuration: cycle)
            XCTAssertEqual(agc.appliedGain, agc.speechGain,
                           "gain must not flicker to unity around the threshold")
        }
    }

    func testGainRampsAfterAStretchOfBleed() {
        var agc = MicAGC()
        feed(&agc, mic: 0.013, system: 0.079, count: 500)
        XCTAssertEqual(agc.appliedGain, 1, "bleed alone never ramps the gain")
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, MicAGC.maxGain, accuracy: 0.01,
                       "owner speech after the bleed ramps normally")
    }

    func testExactlyAtTheDominanceThresholdIsRejected() {
        var agc = MicAGC()
        // Strict >, matching RoleAssigner.micDominanceFactor's comparison.
        agc.update(cycleRMS: 0.02, systemRMS: 0.01, cycleDuration: cycle)
        XCTAssertEqual(agc.speechGain, 1)
        XCTAssertEqual(agc.appliedGain, 1)
    }

    // MARK: Floor

    func testRoomToneBelowTheFloorLeavesTheGainUnchanged() {
        var cold = MicAGC()
        feed(&cold, mic: MicAGC.noiseFloor * 0.9, system: 0, count: 500)
        XCTAssertEqual(cold.speechGain, 1, "room tone must not ramp the gain up")

        var warm = MicAGC()
        feed(&warm, mic: quiet, system: silentSystem, count: cyclesToConverge)
        let ramped = warm.speechGain
        feed(&warm, mic: 0, system: 0, count: 1_000)
        XCTAssertEqual(warm.speechGain, ramped, "silence must not decay the speech gain either")
        XCTAssertEqual(warm.appliedGain, 1, "but silence is mixed at unity")
    }

    func testExactlyAtTheFloorIsAdmitted() {
        var agc = MicAGC()
        agc.update(cycleRMS: MicAGC.noiseFloor, systemRMS: 0, cycleDuration: cycle)
        XCTAssertGreaterThan(agc.speechGain, 1, "the floor is inclusive")
    }

    // MARK: Degenerate input

    func testNonFiniteInputIsRejectedAndDoesNotStick() {
        var agc = MicAGC()
        agc.update(cycleRMS: .infinity, systemRMS: 0, cycleDuration: cycle)
        agc.update(cycleRMS: .nan, systemRMS: 0, cycleDuration: cycle)
        agc.update(cycleRMS: quiet, systemRMS: .infinity, cycleDuration: cycle)
        XCTAssertEqual(agc.speechGain, 1)

        // The poisoned value must not have entered the EMA: ordinary speech
        // still ramps afterwards.
        feed(&agc, mic: quiet, system: silentSystem, count: cyclesToConverge)
        XCTAssertEqual(agc.appliedGain, MicAGC.maxGain, accuracy: 0.01)
    }

    func testZeroCycleDurationIsRejected() {
        var agc = MicAGC()
        agc.update(cycleRMS: quiet, systemRMS: silentSystem, cycleDuration: 0)
        XCTAssertEqual(agc.speechGain, 1)
        XCTAssertEqual(agc.appliedGain, 1)
    }

    // MARK: Gate

    func testDisabledWhenTheKeyIsAbsent() throws {
        let defaults = try makeSuite()
        XCTAssertFalse(MicAGC.isEnabled(defaults), "ships dark until validated on a real recording")
    }

    func testEnabledWhenTheKeyIsTrue() throws {
        let defaults = try makeSuite()
        defaults.set(true, forKey: "transcription.micAGC")
        XCTAssertTrue(MicAGC.isEnabled(defaults))
    }

    func testDisabledWhenTheKeyIsFalse() throws {
        let defaults = try makeSuite()
        defaults.set(false, forKey: "transcription.micAGC")
        XCTAssertFalse(MicAGC.isEnabled(defaults))
    }

    private func makeSuite() throws -> UserDefaults {
        let name = "mic-agc-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
