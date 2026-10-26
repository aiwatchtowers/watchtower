import XCTest
@testable import WatchtowerCore

/// The `watchtower guide learn --json` contract and the D2 signal list.
final class LearnModelTests: XCTestCase {
    private let json = """
    {"cards":[{"id":"chat-ask","title":"Ask the chat","text":"Ask anything.","area":"assistant",\
    "level":"basics","kind":"feature","since":"0.24.0","action":"hotkey:help","changed":"",\
    "done_when":"chat.used","requires":"","replaces":[],"page":"features/chat.md","anchor":"ask",\
    "hotkey_label":"⌘/"},
    {"id":"dictate","title":"Dictate","text":"Say it.","area":"meetings","level":"next","kind":"tip",\
    "since":"0.25.0","action":"","changed":"Now anywhere.","done_when":"dayplan.opened",\
    "requires":"feature:dictation","replaces":["dictate-old"],"page":"","anchor":"","hotkey_label":""}],
    "retired":["dictate-old"]}
    """

    func testDecodesTheContract() throws {
        let catalog = try JSONDecoder().decode(LearnCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.retired, ["dictate-old"])
        XCTAssertEqual(catalog.cards.count, 2)
        let first = catalog.cards[0]
        XCTAssertEqual(first.area, .assistant)
        XCTAssertEqual(first.level, .basics)
        XCTAssertEqual(first.kind, .feature)
        XCTAssertEqual(first.doneWhen, .chatUsed)
        XCTAssertEqual(first.hotkeyLabel, "⌘/")
        XCTAssertEqual(first.anchor, "ask")
        let second = catalog.cards[1]
        // A signal this build does not know is no signal.
        XCTAssertNil(second.doneWhen)
        XCTAssertEqual(second.replaces, ["dictate-old"])
        XCTAssertEqual(second.changed, "Now anywhere.")
        XCTAssertEqual(second.requires, "feature:dictation")
    }

    func testEmptyDoneWhenIsNoSignal() throws {
        let card = try JSONDecoder().decode(LearnCatalog.self, from: Data(json.utf8)).cards[0]
        let data = try XCTUnwrap(json.replacingOccurrences(of: "\"chat.used\"", with: "\"\"").data(using: .utf8))
        XCTAssertNotNil(card.doneWhen)
        XCTAssertNil(try JSONDecoder().decode(LearnCatalog.self, from: data).cards[0].doneWhen)
    }

    /// Plan D2; Go pins the same list in `internal/learn`.
    func testSignalListPinned() {
        XCTAssertEqual(LearnSignal.allCases.map(\.rawValue), [
            "meeting.recorded", "chat.used", "workbench.bound", "reaction.used", "automation.created",
            "memory.on", "calendar.connected", "jira.connected", "linear.connected", "confluence.connected",
            "iphone.paired", "dictation.used"
        ])
    }

    /// §9.3 order; the first four are the onboarding goals' areas.
    func testAreasAndGoals() {
        XCTAssertEqual(LearnArea.allCases.map(\.rawValue), [
            "communication", "meetings", "tasks", "development", "assistant", "planning", "automations",
            "iphone", "setup"
        ])
        XCTAssertEqual(LearnArea(goal: .workCommunication), .communication)
        XCTAssertEqual(LearnArea(goal: .meetings), .meetings)
        XCTAssertEqual(LearnArea(goal: .tasksAndJira), .tasks)
        XCTAssertEqual(LearnArea(goal: .development), .development)
    }

    func testSeenHowMatchesTheCheck() {
        XCTAssertEqual(LearnSeenHow.allCases.map(\.rawValue), ["got_it", "action", "in_use"])
    }
}
