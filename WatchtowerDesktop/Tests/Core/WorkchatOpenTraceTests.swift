import XCTest
@testable import WatchtowerCore

final class WorkchatOpenTraceTests: XCTestCase {
    @MainActor func testReportListsPhaseGapsInMs() {
        let start = ContinuousClock.now
        var t = start
        let trace = WorkchatOpenTrace(sessionID: 7, reopen: false) { t }
        for (phase, ms) in [(WorkchatOpenPhase.appear, 0), (.spawn, 10), (.exit, 650), (.decode, 690), (.adapter, 700), (.paint, 812)] {
            t = start.advanced(by: .milliseconds(ms))
            trace.mark(phase)
        }
        XCTAssertEqual(trace.report, "workchat open session=7 first total=812ms spawn=10 cli=640 decode=40 adapter=10 paint=112")
    }

    @MainActor func testReportNilUntilPaint() {
        let trace = WorkchatOpenTrace(sessionID: 7, reopen: true)
        trace.mark(.appear); trace.mark(.spawn)
        XCTAssertNil(trace.report)
    }

    @MainActor func testSecondPaintDoesNotReport() {
        let start = ContinuousClock.now
        var t = start
        let trace = WorkchatOpenTrace(sessionID: 7, reopen: true) { t }
        trace.mark(.appear)
        t = start.advanced(by: .milliseconds(5))
        trace.mark(.paint)
        let first = trace.report
        XCTAssertEqual(first, "workchat open session=7 reopen total=5ms spawn=- cli=- decode=- adapter=- paint=5")
        t = start.advanced(by: .milliseconds(900))
        trace.mark(.paint)
        XCTAssertEqual(trace.report, first)
    }

    @MainActor func testRepeatedPhaseKeepsFirstMark() {
        let start = ContinuousClock.now
        var t = start
        let trace = WorkchatOpenTrace(sessionID: 1, reopen: false) { t }
        trace.mark(.appear)
        t = start.advanced(by: .milliseconds(10)); trace.mark(.spawn)
        t = start.advanced(by: .milliseconds(500)); trace.mark(.spawn)
        t = start.advanced(by: .milliseconds(520)); trace.mark(.paint)
        XCTAssertEqual(trace.report, "workchat open session=1 first total=520ms spawn=10 cli=- decode=- adapter=- paint=510")
    }

    @MainActor func testMarksAfterPaintAreIgnored() {
        let start = ContinuousClock.now
        var t = start
        let trace = WorkchatOpenTrace(sessionID: 1, reopen: false) { t }
        trace.mark(.appear)
        t = start.advanced(by: .milliseconds(20)); trace.mark(.paint)
        let report = trace.report
        t = start.advanced(by: .milliseconds(900))
        trace.mark(.spawn); trace.mark(.exit); trace.mark(.paint)
        XCTAssertEqual(trace.report, report)
    }

    @MainActor func testStoreKeepsOneLiveTraceAndReplacesAFinishedOne() {
        let store = SessionFeedStore(sessionID: 3, runner: nil)
        let first = store.openTrace
        XCTAssertNotNil(first)
        store.beginOpenTrace(reopen: true)
        XCTAssertTrue(store.openTrace === first, "a live trace is kept")
        first?.mark(.paint)
        store.beginOpenTrace(reopen: true)
        XCTAssertFalse(store.openTrace === first, "a finished trace is replaced")
        XCTAssertNil(store.openTrace?.report)
    }
}
