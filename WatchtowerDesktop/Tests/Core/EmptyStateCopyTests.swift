import XCTest
@testable import WatchtowerCore

final class EmptyStateCopyTests: XCTestCase {
    /// Every raw value the table covers (SidebarDestination is Desktop-side;
    /// EmptyStateCopyCoverageTests sweeps the real enum).
    private let covered = [
        "catchUp", "briefings", "dayPlan", "inbox", "ideas", "calendar", "targets", "tracks", "projects", "automations",
        "digests", "people", "memory", "workload", "blockers", "projectMap", "releases", "statistics",
        "inboxMessages", "inboxAutomations", "inboxFolder"
    ]

    private func copy(_ rawValue: String, briefingHour: Int = 8) -> EmptyStateCopy? {
        EmptyStateCopyTable.copy(for: rawValue, briefingHour: briefingHour)
    }

    func testBriefingsCopyNamesConfiguredHour() throws {
        let text = try XCTUnwrap(copy("briefings", briefingHour: 7)).landsHere
        XCTAssertTrue(text.contains("07:00"), text)
        XCTAssertFalse(text.contains("after sync"), text)
        XCTAssertFalse(text.contains("{hour}"), text)
        XCTAssertEqual(
            text, "A morning briefing: meetings, what needs you, what changed. Generated once a day at or after 07:00.")
    }

    /// The Inbox's root, empty, speaks of automations and offers New
    /// Artifact… (inbox builder B); the Getting ready card keeps what the
    /// Inbox holds; its Automations filter keeps B's proposals-and-reminders
    /// sentence (owner, ask #299).
    func testInboxCopySaysProposalsAndReminders() throws {
        let root = try XCTUnwrap(copy("inbox"))
        XCTAssertEqual(root.title, "Your Inbox is empty")
        XCTAssertEqual(root.landsHere, "Automations put what they make here.")
        XCTAssertEqual(root.primaryAction, .tabAction(label: "New Artifact…"))
        XCTAssertEqual(
            EmptyStateCopyTable.featureCard(.inbox, briefingHour: 8).whatItIs,
            "Your day, messages, tracks, ideas and automation cards that need you.")
        XCTAssertEqual(
            try XCTUnwrap(copy("inboxAutomations")).landsHere,
            "Proposals and due reminders that need you, plus reaction shortcuts.")
    }

    /// An owner folder names itself; Needs approval says only its title.
    func testInboxFolderCopies() throws {
        let folder = try XCTUnwrap(EmptyStateCopyTable.copy(for: "inboxFolder", briefingHour: 8, folderTitle: "Release"))
        XCTAssertEqual(folder.title, "Nothing in Release yet")
        XCTAssertEqual(folder.landsHere, "Move an automation here from its ⋯ menu, or make a new one.")
        XCTAssertEqual(folder.primaryAction, .tabAction(label: "New Artifact…"))
        let approvals = try XCTUnwrap(copy("inboxApprovals"))
        XCTAssertEqual(approvals.title, "Nothing waits for your approval")
        XCTAssertNil(approvals.primaryAction)
        XCTAssertNil(approvals.feature)
    }

    func testEveryInboxFilterHasCopy() {
        for filter in InboxFilter.allCases {
            XCTAssertNotNil(copy(filter.emptyCopyKey), filter.rawValue)
        }
    }

    /// `day_plan.hour` is retired: the plan is made with the brief, after the briefing hour.
    func testDayPlanCopyNamesBriefingHour() throws {
        let text = try XCTUnwrap(copy("dayPlan", briefingHour: 7)).landsHere
        XCTAssertTrue(text.contains("07:00"), text)
        XCTAssertFalse(text.contains("{hour}"), text)
    }

    func testNoHourGatedCopySaysAfterSync() throws {
        for hour in [0, 8, 23] {
            for rawValue in ["briefings", "dayPlan"] {
                let text = try XCTUnwrap(copy(rawValue, briefingHour: hour)).landsHere
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
