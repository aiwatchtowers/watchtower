import XCTest
@testable import WatchtowerCore

final class EmptyStateCopyTests: XCTestCase {
    /// Every raw value the table covers (SidebarDestination is Desktop-side;
    /// EmptyStateCopyCoverageTests sweeps the real enum).
    private let covered = [
        "catchUp", "briefings", "dayPlan", "inbox", "ideas", "calendar", "targets", "tracks", "projects",
        "digests", "people", "memory", "workload", "blockers", "projectMap", "releases", "statistics", "boards"
    ]

    private func copy(_ rawValue: String, briefingHour: Int = 8, dayPlanHour: Int = 8) -> EmptyStateCopy? {
        EmptyStateCopyTable.copy(for: rawValue, briefingHour: briefingHour, dayPlanHour: dayPlanHour)
    }

    func testBriefingsCopyNamesConfiguredHour() throws {
        let text = try XCTUnwrap(copy("briefings", briefingHour: 7)).landsHere
        XCTAssertTrue(text.contains("07:00"), text)
        XCTAssertFalse(text.contains("after sync"), text)
        XCTAssertFalse(text.contains("{hour}"), text)
        XCTAssertEqual(
            text, "A morning briefing: meetings, what needs you, what changed. Generated once a day at or after 07:00.")
    }

    func testDayPlanCopyNamesConfiguredHour() throws {
        let text = try XCTUnwrap(copy("dayPlan", briefingHour: 7, dayPlanHour: 9)).landsHere
        XCTAssertTrue(text.contains("09:00"), text)
        XCTAssertFalse(text.contains("07:00"), "the day plan uses its own hour: \(text)")
        XCTAssertFalse(text.contains("{hour}"), text)
    }

    func testNoHourGatedCopySaysAfterSync() throws {
        for hour in [0, 8, 23] {
            for rawValue in ["briefings", "dayPlan"] {
                let text = try XCTUnwrap(copy(rawValue, briefingHour: hour, dayPlanHour: hour)).landsHere
                XCTAssertFalse(text.localizedCaseInsensitiveContains("after sync"), "\(rawValue): \(text)")
            }
        }
    }

    func testTurnOnOnlyForFeaturesWithSwitch() throws {
        var turnOns = 0
        for rawValue in covered {
            let row = try XCTUnwrap(copy(rawValue), rawValue)
            XCTAssertFalse(row.title.isEmpty, rawValue)
            XCTAssertFalse(row.landsHere.isEmpty, rawValue)
            guard case .turnOn(let id) = row.primaryAction else { continue }
            turnOns += 1
            XCTAssertNotNil(row.feature?.featureID, rawValue)
            XCTAssertEqual(id, row.feature?.featureID, rawValue)
        }
        XCTAssertGreaterThan(turnOns, 0, "Memory turns on from its empty state")
    }

    func testUnknownRawValueReturnsNil() {
        XCTAssertNil(copy("nope"))
        XCTAssertNil(copy("workbench"), "Workbench is keyed by its persisted raw value, \"projects\"")
        for rawValue in EmptyStateCopyTable.exempt {
            XCTAssertNil(copy(rawValue), rawValue)
        }
    }
}
