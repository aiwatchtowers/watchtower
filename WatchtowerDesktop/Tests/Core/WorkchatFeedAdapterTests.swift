import ChatWire
import Foundation
@testable import WatchtowerCore
import XCTest
import WatchtowerChatText

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

        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user", "system", "system", "system"],
                       "a subagent marker and an unknown kind are left out")
        XCTAssertEqual(messages.map(\.text), ["The brief", "Fix the build", "On it.", "Yes", "Rebase on main", "Done", ""])
        XCTAssertEqual(messages.map(\.id), entries.filter { !["subagent", "future_kind"].contains($0.kind) }
            .map { WorkchatFeedAdapter.messageID($0.id) })
        XCTAssertEqual(Set(messages.map(\.id)).count, messages.count, "ids stay distinct")
        XCTAssertEqual(messages[1].createdAt, at)
        XCTAssertEqual(messages[0].createdAt, .distantPast, "no time for the brief")
        XCTAssertTrue(messages.allSatisfy { $0.parts == nil && $0.status == "complete" })
        XCTAssertEqual(WorkchatFeedAdapter.messageID("e2"), WorkchatFeedAdapter.messageID("e2"), "stable across reads")
        XCTAssertGreaterThanOrEqual(WorkchatFeedAdapter.messageID("e2"), 0)

        let time = at.formatted(.dateTime.hour().minute())
        XCTAssertEqual(WorkchatFeedAdapter.caption(entries[3]), ["via Watchtower", time])
        XCTAssertEqual(WorkchatFeedAdapter.caption(entries[1]), [time])
        XCTAssertEqual(WorkchatFeedAdapter.caption(entries[0]), [])
        XCTAssertEqual(WorkchatFeedAdapter.askHeader(entries[3])?.label, "Ask #12")
        XCTAssertEqual(WorkchatFeedAdapter.askHeader(entries[3])?.title, "Ship it?")
        XCTAssertEqual(WorkchatFeedAdapter.askHeader(SessionFeedEntry(id: "x", kind: "ask_answer", text: "No"))?.label, "Ask")
        XCTAssertNil(WorkchatFeedAdapter.askHeader(entries[1]))
    }

    /// #2065: agents leave the conversation; they live in the 👥 list.
    func testSubagentEntryMapsToNoMessage() {
        let entries = [entry("o1", kind: "owner"), entry("s1", kind: "subagent"), entry("a1", kind: "agent")]
        XCTAssertEqual(WorkchatFeedAdapter.messages(entries).map(\.id), ["o1", "a1"].map(WorkchatFeedAdapter.messageID))
        XCTAssertNil(WorkchatFeedAdapter.role(for: "subagent"))
    }

    func testDialogLeavesMarkersOut() {
        let entries = [entry("s1", kind: "subagent"), entry("o1", kind: "owner"), entry("s2", kind: "subagent")]
        XCTAssertEqual(WorkchatFeedAdapter.dialog(entries).map(\.id), ["o1"])
        XCTAssertTrue(WorkchatFeedAdapter.dialog([entry("s1", kind: "subagent")]).isEmpty, "markers only: the empty state")
    }

    private func entry(_ id: String, kind: String) -> SessionFeedEntry {
        SessionFeedEntry(id: id, kind: kind, text: id,
                         subagent: kind == "subagent" ? SessionFeedSubagent(toolUseID: "tu-\(id)", status: "running") : nil)
    }
}
