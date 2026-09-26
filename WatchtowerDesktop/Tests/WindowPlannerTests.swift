import XCTest
@testable import WatchtowerDesktop

final class WindowPlannerTests: XCTestCase {

    /// windowSec 0.1 (1600 samples), overlap 0, snap 0.02 (320 samples,
    /// under the windowSamples/4 = 400 cap).
    private func config(snap: Double = 0.02, overlap: Double = 0) -> TranscriptionConfig {
        var c = TranscriptionConfig()
        c.windowSec = 0.1
        c.overlapSec = overlap
        c.boundarySnapSec = snap
        return c
    }

    /// Loud everywhere except a quiet dip of `dipLen` samples at `dipStart`.
    private func samples(count: Int, dipStart: Int, dipLen: Int) -> [Float] {
        var s = [Float](repeating: 0.5, count: count)
        for i in dipStart..<min(dipStart + dipLen, count) { s[i] = 0.0 }
        return s
    }

    func testSnapDisabledGivesNominalBoundaries() {
        let planner = WindowPlanner(config: config(snap: 0))
        let s = [Float](repeating: 0.5, count: 5600)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges, [0..<1600, 1600..<3200, 3200..<4800, 4800..<5600])
    }

    func testCutSnapsToQuietDip() {
        // Dip covers samples 1700..<2100; the zone for window 0 is [1280, 1920].
        // Frame candidates start at 1280/1440/1600; the frame at 1600 holds the
        // most quiet samples (220 of 320) → cut at its centre, 1600 + 160.
        let planner = WindowPlanner(config: config())
        let s = samples(count: 6000, dipStart: 1700, dipLen: 400)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges[0], 0..<1760)
        XCTAssertEqual(ranges[1].lowerBound, 1760) // overlap 0 → next start = cut
    }

    func testAllSilenceCutsAtEarliestFrame() {
        // Equal energy everywhere → earliest frame in the zone wins (strict <).
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.0, count: 6000)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        // Zone [1280, 1920], earliest frame at 1280 → cut 1280 + 160 = 1440.
        XCTAssertEqual(ranges[0], 0..<1440)
    }

    func testLastWindowIsNeverSnapped() {
        let planner = WindowPlanner(config: config())
        let s = samples(count: 1600, dipStart: 800, dipLen: 100)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges, [0..<1600]) // exact-length recording = one window
    }

    func testZoneClampedByTotal() {
        // total = 1700 lies inside the zone [1280, 1920] → the zone ends at
        // 1700 and only the frame at 1280 fits; the window at 0 is non-last.
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.5, count: 1700)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges[0].upperBound, 1440) // 1280 + 160
        XCTAssertEqual(ranges.last?.upperBound, 1700) // tail window to the end
    }

    func testTinyWindowZoneSmallerThanFrameFallsBackToNominal() {
        // windowSec 0.01 → 160 samples, tolerance cap 160/4 = 40 → zone of 80
        // samples cannot fit one 320-sample frame → nominal cut.
        var c = TranscriptionConfig()
        c.windowSec = 0.01
        c.overlapSec = 0
        c.boundarySnapSec = 2.5
        let planner = WindowPlanner(config: c)
        let s = [Float](repeating: 0.5, count: 400)
        let ranges = planner.planWindows(total: s.count) { s[$0] }
        XCTAssertEqual(ranges, [0..<160, 160..<320, 320..<400])
    }

    func testNextRangeNotDecidableUntilZoneBuffered() {
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.5, count: 1900) // decidable needs 1600 + 320
        XCTAssertNil(planner.nextRange(start: 0, total: 1900, isFinal: false) { s[$0] })
        XCTAssertNotNil(planner.nextRange(start: 0, total: 1900, isFinal: true) { s[$0] })
    }

    func testNextRangeLastWindowOnlyWhenFinal() {
        let planner = WindowPlanner(config: config())
        let s = [Float](repeating: 0.5, count: 1000)
        XCTAssertNil(planner.nextRange(start: 0, total: 1000, isFinal: false) { s[$0] })
        XCTAssertEqual(planner.nextRange(start: 0, total: 1000, isFinal: true) { s[$0] }, 0..<1000)
    }

    func testOverlapAppliedToSnappedCut() {
        // overlap 0.05 s = 800 samples: next start = cut − 800.
        let planner = WindowPlanner(config: config(snap: 0.02, overlap: 0.05))
        XCTAssertEqual(planner.nextStart(after: 0..<1440), 640)
    }

    func testEmptyInputPlansNothing() {
        let planner = WindowPlanner(config: config())
        XCTAssertEqual(planner.planWindows(total: 0) { _ in 0 }, [])
    }
}
