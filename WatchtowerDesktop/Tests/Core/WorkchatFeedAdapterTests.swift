import ChatWire
import Foundation
@testable import WatchtowerCore
import XCTest

/// Workchat's session feed reaches ChatUI's feed: the owner's lines and ask answers as the owner's, the agent's text as
/// the answer, everything else as `system` lines the Mac draws itself.
final class WorkchatFeedAdapterTests: XCTestCase {
    func testWorkchatAdapterMapsFeedRows() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            SessionFeedEntry(id: "e1", kind: "brief", text: "The brief"),
            SessionFeedEntry(id: "e2", kind: "owner", at: at, text: "Fix the build"),
            SessionFeedEntry(id: "e3", kind: "agent", at: at, text: "On it."),
            SessionFeedEntry(id: "e4", kind: "ask_answer", at: at, text: "Yes", askID: 12, title: "Ship it?"),
            SessionFeedEntry(id: "e5", kind: "watchtower", at: at, text: "Rebase on main"),
            SessionFeedEntry(id: "e6", kind: "subagent", subagent: SessionFeedSubagent(toolUseID: "tu1", type: "Explore")),
            SessionFeedEntry(id: "e7", kind: "event", text: "Done", title: "Task finished", eventType: "task"),
            SessionFeedEntry(id: "e8", kind: "separator"),
            SessionFeedEntry(id: "e9", kind: "future_kind", text: "?")
        ]

        let messages = WorkchatFeedAdapter.messages(entries)

        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user", "system", "system", "system", "system"],
                       "an unknown kind is left out")
        XCTAssertEqual(messages.map(\.text), ["The brief", "Fix the build", "On it.", "Yes", "Rebase on main", "", "Done", ""])
        XCTAssertEqual(messages.map(\.id), entries.dropLast().map { WorkchatFeedAdapter.messageID($0.id) })
        XCTAssertEqual(Set(messages.map(\.id)).count, messages.count, "ids stay distinct")
        XCTAssertEqual(messages[1].createdAt, at)
        XCTAssertEqual(messages[0].createdAt, .distantPast, "no time for the brief")
        XCTAssertTrue(messages.allSatisfy { $0.parts == nil && $0.status == "complete" })
        XCTAssertEqual(WorkchatFeedAdapter.messageID("e2"), WorkchatFeedAdapter.messageID("e2"), "stable across reads")
        XCTAssertGreaterThanOrEqual(WorkchatFeedAdapter.messageID("e2"), 0)

        let time = at.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(WorkchatFeedAdapter.caption(entries[3]), "Ask #12: Ship it? · via Watchtower · \(time)")
        XCTAssertEqual(WorkchatFeedAdapter.caption(entries[1]), time)
        XCTAssertNil(WorkchatFeedAdapter.caption(entries[0]))
        XCTAssertEqual(WorkchatFeedAdapter.caption(SessionFeedEntry(id: "x", kind: "ask_answer", text: "No")),
                       "Ask · via Watchtower")
    }
}
