import XCTest
@testable import WatchtowerDesktop

/// The mute ramp behind "your voice is not recorded": the recorder scales
/// every mic sample of a cycle by `start + step * frame`.
final class MicMuteTests: XCTestCase {

    private func gains(_ ramp: (start: Float, step: Float), frameCount: Int) -> [Float] {
        (0..<frameCount).map { ramp.start + ramp.step * Float($0) }
    }

    func testUnmutedCyclesPassTheMicThrough() {
        var mute = MicMute()
        XCTAssertEqual(gains(mute.ramp(frameCount: 4), frameCount: 4), [1, 1, 1, 1])
    }

    /// The muting cycle glides down and ends exactly at 0; every cycle after
    /// it is silent to the bit.
    func testMuteGlidesToExactSilence() {
        var mute = MicMute()
        mute.muted = true
        let first = gains(mute.ramp(frameCount: 4), frameCount: 4)
        XCTAssertEqual(first, [0.75, 0.5, 0.25, 0])
        XCTAssertEqual(mute.gain, 0)
        for _ in 0..<3 {
            XCTAssertEqual(gains(mute.ramp(frameCount: 512), frameCount: 512), Array(repeating: 0, count: 512))
        }
    }

    /// Unmuting glides back up without a jump bigger than one step.
    func testUnmuteGlidesBackWithoutAJump() {
        var mute = MicMute()
        mute.muted = true
        _ = mute.ramp(frameCount: 256)
        mute.muted = false
        let frames = 256
        let up = gains(mute.ramp(frameCount: frames), frameCount: frames)
        XCTAssertEqual(up.last ?? 0, 1, accuracy: 1e-5)
        var previous: Float = 0
        for gain in up {
            XCTAssertLessThanOrEqual(gain - previous, 1 / Float(frames) + 1e-6)
            previous = gain
        }
        XCTAssertEqual(gains(mute.ramp(frameCount: 4), frameCount: 4), [1, 1, 1, 1])
    }
}
