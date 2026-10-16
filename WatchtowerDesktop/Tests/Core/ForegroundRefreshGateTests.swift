import Foundation
import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Board #731: the visibility gate of the UI pollers, the on-screen rule
/// over the app's windows, and the one-read calendar window that replaced a
/// query per day.
final class ForegroundRefreshGateTests: XCTestCase {
    // MARK: - ForegroundRefreshGate

    func testOnScreenEveryTickRefreshes() {
        var gate = ForegroundRefreshGate()
        XCTAssertTrue(gate.tick())
        XCTAssertTrue(gate.tick())
    }

    func testOffScreenTicksAreSkippedAndTheReturnRefreshesOnce() {
        var gate = ForegroundRefreshGate()
        XCTAssertFalse(gate.setOnScreen(false))
        XCTAssertFalse(gate.tick())
        XCTAssertFalse(gate.tick())
        XCTAssertTrue(gate.setOnScreen(true), "back on screen after a skipped tick: one refresh now")
        XCTAssertFalse(gate.setOnScreen(true), "already on screen: no second refresh")
        XCTAssertTrue(gate.tick())
    }

    func testAShortAbsenceWithoutASkippedTickDoesNotRefresh() {
        var gate = ForegroundRefreshGate()
        XCTAssertFalse(gate.setOnScreen(false))
        XCTAssertFalse(gate.setOnScreen(true), "nothing was skipped, the data is one tick old at most")
    }

    func testTheSkipIsForgottenAfterTheRefresh() {
        var gate = ForegroundRefreshGate()
        _ = gate.setOnScreen(false)
        _ = gate.tick()
        XCTAssertTrue(gate.setOnScreen(true))
        _ = gate.setOnScreen(false)
        XCTAssertFalse(gate.setOnScreen(true), "the earlier skip was already refreshed")
    }

    func testAGateStartedOffScreenSkipsItsFirstTick() {
        var gate = ForegroundRefreshGate(isOnScreen: false)
        XCTAssertFalse(gate.isOnScreen)
        XCTAssertFalse(gate.tick())
        XCTAssertTrue(gate.setOnScreen(true))
    }

    // MARK: - UIVisibilityPolicy

    private func window(
        main: Bool = true, visible: Bool = true, miniaturized: Bool = false, occluded: Bool = false
    ) -> UIVisibilityPolicy.Window {
        UIVisibilityPolicy.Window(canBecomeMain: main, isVisible: visible, isMiniaturized: miniaturized, isOccluded: occluded)
    }

    func testAVisibleUncoveredWindowIsOnScreen() {
        XCTAssertTrue(UIVisibilityPolicy.isOnScreen([window()], appHidden: false))
    }

    func testNoWindowIsOffScreen() {
        XCTAssertFalse(UIVisibilityPolicy.isOnScreen([], appHidden: false))
    }

    func testHiddenMinimisedCoveredOrStatusWindowsAreOffScreen() {
        XCTAssertFalse(UIVisibilityPolicy.isOnScreen([window(visible: false)], appHidden: false))
        XCTAssertFalse(UIVisibilityPolicy.isOnScreen([window(miniaturized: true)], appHidden: false))
        XCTAssertFalse(UIVisibilityPolicy.isOnScreen([window(occluded: true)], appHidden: false))
        XCTAssertFalse(
            UIVisibilityPolicy.isOnScreen([window(main: false)], appHidden: false),
            "the menu-bar extra's status window is always visible and never counts"
        )
    }

    func testAHiddenAppIsOffScreenWhateverItsWindowsSay() {
        XCTAssertFalse(UIVisibilityPolicy.isOnScreen([window()], appHidden: true))
    }

    func testOneWindowOnScreenAmongOthersIsEnough() {
        XCTAssertTrue(UIVisibilityPolicy.isOnScreen(
            [window(occluded: true), window(main: false), window()], appHidden: false
        ))
    }

    // MARK: - CalendarQueries.fetchEventsByDay

    private static let iso: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// The one read returns per day exactly what a query per day returned,
    /// a multi-day event in every day it overlaps and empty days left out.
    func testEventsByDayMatchesAQueryPerDay() throws {
        let queue = try TestDatabase.create()
        let today = Calendar.current.startOfDay(for: Date())
        let days = (-2 ..< 3).map { today.addingTimeInterval(Double($0) * 86400) }
        try queue.write { db in
            func insert(_ id: String, from: TimeInterval, to: TimeInterval) throws {
                try TestDatabase.insertCalendarEvent(
                    db, id: id,
                    startTime: Self.iso.string(from: today.addingTimeInterval(from)),
                    endTime: Self.iso.string(from: today.addingTimeInterval(to))
                )
            }
            try insert("yesterday", from: -86400 + 3600, to: -86400 + 7200)
            try insert("today", from: 3600, to: 5400)
            try insert("today-late", from: 20 * 3600, to: 21 * 3600)
            try insert("overnight", from: 23 * 3600, to: 25 * 3600)
            try insert("far", from: 30 * 86400, to: 30 * 86400 + 3600)
        }
        let grouped = try queue.read { try CalendarQueries.fetchEventsByDay($0, dayStarts: days) }
        let perDay = try queue.read { db in
            try days.compactMap { day -> (Date, [String])? in
                let ids = try CalendarQueries.fetchEvents(db, from: day, to: day.addingTimeInterval(86400)).map(\.id)
                return ids.isEmpty ? nil : (day, ids)
            }
        }
        XCTAssertEqual(grouped.map(\.day), perDay.map(\.0))
        XCTAssertEqual(grouped.map { $0.events.map(\.id) }, perDay.map(\.1))
        XCTAssertEqual(grouped.first { $0.day == today }?.events.map(\.id), ["today", "today-late", "overnight"])
        XCTAssertEqual(grouped.first { $0.day == days[3] }?.events.map(\.id), ["overnight"])
    }

    /// A far pinned day is read on its own: the result still matches a
    /// query per day, and nothing of the gap comes back.
    func testEventsByDayWithAGapMatchesAQueryPerDay() throws {
        let queue = try TestDatabase.create()
        let today = Calendar.current.startOfDay(for: Date())
        let pinned = today.addingTimeInterval(40 * 86400)
        let days = [today, today.addingTimeInterval(86400), pinned]
        try queue.write { db in
            func insert(_ id: String, at day: Date) throws {
                try TestDatabase.insertCalendarEvent(
                    db, id: id,
                    startTime: Self.iso.string(from: day.addingTimeInterval(3600)),
                    endTime: Self.iso.string(from: day.addingTimeInterval(7200))
                )
            }
            try insert("today", at: today)
            try insert("gap", at: today.addingTimeInterval(20 * 86400))
            try insert("pinned", at: pinned)
        }
        let grouped = try queue.read { try CalendarQueries.fetchEventsByDay($0, dayStarts: days) }
        XCTAssertEqual(grouped.map(\.day), [today, pinned])
        XCTAssertEqual(grouped.map { $0.events.map(\.id) }, [["today"], ["pinned"]])
    }

    func testEventsByDayOfNoDaysIsEmpty() throws {
        let queue = try TestDatabase.create()
        XCTAssertTrue(try queue.read { try CalendarQueries.fetchEventsByDay($0, dayStarts: []) }.isEmpty)
    }
}
