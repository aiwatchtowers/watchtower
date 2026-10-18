import XCTest
@testable import WatchtowerCore

final class ReactionAutomationRowsTests: XCTestCase {
    private func item(_ id: Int64, _ name: String, kind: String = "event", spec: String) -> AutomationListItem {
        let automation = Automation(
            id: id, slug: name.lowercased(), name: name, triggerKind: kind, triggerSpecJSON: spec
        )
        return AutomationListItem(automation: automation, lastRun: nil, activeRun: nil, tokens7d: 0,
                                  badges: [], triggerText: "")
    }

    func testPicksOnlyReactionEventItems() {
        let rows = ReactionAutomationRows.rows(from: [
            item(1, "Mail", spec: #"{"event":{"type":"gmail.new_messages"}}"#),
            item(2, "React", spec: #"{"event":{"type":"slack.reaction_added"}}"#),
            item(3, "Nightly", kind: "schedule", spec: #"{"schedule":"0 9 * * *"}"#),
            item(4, "Manual", kind: "manual", spec: #"{"manual":true}"#),
            item(5, "Wrong kind", kind: "button", spec: #"{"event":{"type":"slack.reaction_added"}}"#)
        ])
        XCTAssertEqual(rows.map(\.id), [2])
    }

    func testReadsEmojiAndLeavesNilWithoutWhere() {
        let rows = ReactionAutomationRows.rows(from: [
            item(1, "A", spec: #"{"event":{"type":"slack.reaction_added","where":{"emoji":"eyes"}}}"#),
            item(2, "B", spec: #"{"event":{"type":"slack.reaction_added"}}"#),
            item(3, "C", spec: #"{"event":{"type":"slack.reaction_added","where":{"account":"work"}}}"#)
        ])
        XCTAssertEqual(rows, [
            ReactionAutomationRow(id: 1, name: "A", emoji: "eyes"),
            ReactionAutomationRow(id: 2, name: "B", emoji: nil),
            ReactionAutomationRow(id: 3, name: "C", emoji: nil)
        ])
    }

    func testStripsSurroundingColonsFromEmoji() {
        let rows = ReactionAutomationRows.rows(from: [
            item(1, "A", spec: #"{"event":{"type":"slack.reaction_added","where":{"emoji":":eyes:"}}}"#)
        ])
        XCTAssertEqual(rows.first?.emoji, "eyes")
    }

    func testSortsByNameCaseInsensitively() {
        let spec = #"{"event":{"type":"slack.reaction_added"}}"#
        let rows = ReactionAutomationRows.rows(from: [
            item(1, "beta", spec: spec), item(2, "Alpha", spec: spec), item(3, "charlie", spec: spec)
        ])
        XCTAssertEqual(rows.map(\.name), ["Alpha", "beta", "charlie"])
    }

    func testMalformedSpecIsSkipped() {
        XCTAssertEqual(ReactionAutomationRows.rows(from: [item(1, "X", spec: "not json")]), [])
    }
}
