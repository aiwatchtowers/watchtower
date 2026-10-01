import XCTest
@testable import WatchtowerCore

final class CallAudioWatchTests: XCTestCase {
    /// `seconds` of 100 ms bins at `level`.
    private func bins(_ seconds: Double, _ level: Float) -> [Float] {
        Array(repeating: level, count: Int((seconds * 10).rounded()))
    }

    private let call: Float = 0.05
    private let dead: Float = 0

    func testSteadyCallHasNoGap() {
        XCTAssertEqual(CallAudioWatch.gaps(system: bins(600, call)), [])
    }

    // The reported recording: the call is heard, then the tap goes silent
    // for the rest of the meeting.
    func testCallThatGoesSilentForGoodIsAnOpenGap() {
        let gaps = CallAudioWatch.gaps(system: bins(90, call) + bins(200, dead))
        XCTAssertEqual(gaps, [CallAudioWatch.Gap(startSec: 90, endSec: nil)])
    }

    func testCallAudioComingBackClosesTheGap() {
        let gaps = CallAudioWatch.gaps(system: bins(90, call) + bins(200, dead) + bins(30, call))
        XCTAssertEqual(gaps, [CallAudioWatch.Gap(startSec: 90, endSec: 290)])
    }

    // A stray click or notification in the silence is not the call coming
    // back.
    func testABlipDoesNotEndAGap() {
        let gaps = CallAudioWatch.gaps(system: bins(90, call) + bins(100, dead) + bins(1.5, call) + bins(100, dead))
        XCTAssertEqual(gaps, [CallAudioWatch.Gap(startSec: 90, endSec: nil)])
    }

    // An app that outputs digital silence between words: the other side
    // talks in short turns with silent gaps — that is a live call, not a
    // gap.
    func testChoppyRemoteSpeechIsNoGap() {
        let turns = (0..<40).flatMap { _ in bins(3, call) + bins(6, dead) }
        XCTAssertEqual(CallAudioWatch.gaps(system: bins(120, call) + turns), [])
    }

    func testAShortPauseIsNoGap() {
        XCTAssertEqual(CallAudioWatch.gaps(system: bins(90, call) + bins(100, dead) + bins(30, call)), [])
    }

    // Degenerate: a room-only meeting (no call at all) and a recording that
    // starts silent before the call is heard are not gaps.
    func testNoCallOrSilenceBeforeTheCallIsNoGap() {
        var room = CallAudioWatch()
        bins(1800, dead).forEach { room.add(system: $0) }
        XCTAssertEqual(room.gaps, [])
        XCTAssertTrue(room.neverHeardCall)

        XCTAssertEqual(CallAudioWatch.gaps(system: bins(300, dead) + bins(300, call)), [])
        XCTAssertEqual(CallAudioWatch.gaps(system: []), [])
    }

    // A room meeting whose system channel only carries the odd notification
    // was never "hearing a call", so its silence is no gap.
    func testOccasionalNotificationsAreNotACall() {
        let notifications = (0..<10).flatMap { _ in bins(2, call) + bins(178, dead) }
        XCTAssertEqual(CallAudioWatch.gaps(system: notifications), [])
    }

    // Live use: the open gap appears only once the silence has lasted
    // `minGapSec`, and disappears when the call comes back.
    func testOpenGapAppearsAfterMinGapAndClearsOnResume() {
        var watch = CallAudioWatch()
        (bins(90, call) + bins(119, dead)).forEach { watch.add(system: $0) }
        XCTAssertNil(watch.openGap)
        bins(2, dead).forEach { watch.add(system: $0) }
        XCTAssertEqual(watch.openGap, CallAudioWatch.Gap(startSec: 90, endSec: nil))
        XCTAssertFalse(watch.neverHeardCall)
        bins(5, call).forEach { watch.add(system: $0) }
        XCTAssertNil(watch.openGap)
    }
}
