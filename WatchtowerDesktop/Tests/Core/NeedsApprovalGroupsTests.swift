import GRDB
import XCTest
@testable import WatchtowerCore

/// Needs approval grouped by kind (spec "Needs approval", phase 1): the
/// groups, their order, and **Approve All** as an allowlist — never a
/// message, a reminder, a connector call or an unknown tool.
final class NeedsApprovalGroupsTests: XCTestCase {
    private static let now = AutomationDates.parse("2026-11-06T10:00:00Z") ?? Date()
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private static func action(
        _ id: Int64,
        tool: String,
        created: String = "2026-11-06T09:00:00Z",
        status: String = "pending",
        args: String = "{}",
        reason: String = "r",
        surface: String = "main",
        contextType: String = ""
    ) -> NeedsApprovalItem {
        NeedsApprovalItem(.action(AgentAction(row: Row([
            "id": id, "tool": tool, "args_json": args, "status": status, "surface": surface, "reason": reason,
            "context_type": contextType, "created_at": created
        ]))))
    }

    private static func reminder(_ id: Int64, created: String = "2026-11-06T08:00:00Z") -> NeedsApprovalItem {
        NeedsApprovalItem(.reminder(Reminder(row: Row([
            "id": id, "note": "Answer colleague A", "remind_at": "2026-11-06T09:30:00Z", "status": "pending",
            "created_at": created
        ]))))
    }

    private static func many(_ tool: String, _ count: Int, from first: Int64 = 1) -> [NeedsApprovalItem] {
        (0..<count).map { action(first + Int64($0), tool: tool, created: "2026-11-06T09:0\($0):00Z") }
    }

    func testToolsMapToGroups() {
        let expected: [String: NeedsApprovalGroup] = [
            "send_slack_message": .messages, "add_jira_comment": .messages, "add_linear_comment": .messages,
            "create_track": .tracksToCreate,
            "create_target": .targets, "create_targets": .targets, "update_target": .targets,
            "edit_confluence_page": .confluenceJira, "connect_jira_board": .confluenceJira,
            "create_jira_issue": .confluenceJira, "update_jira_issue": .confluenceJira,
            "transition_jira_issue": .confluenceJira, "assign_jira_issue": .confluenceJira,
            ConnectorCallProposal.tool: .other, "create_linear_issue": .other, "save_automation": .other,
            "a_tool_added_later": .other
        ]
        for (tool, group) in expected {
            XCTAssertEqual(NeedsApprovalGroup.of(Self.action(1, tool: tool)), group, tool)
        }
        XCTAssertEqual(NeedsApprovalGroup.of(Self.reminder(1)), .reminders)
        XCTAssertEqual(NeedsApprovalGroup.allCases.map(\.title),
                       ["Messages", "Tracks to create", "Targets", "Confluence and Jira", "Reminders", "Other"])
    }

    func testGroupsSortByOldestItem() {
        let items = [
            Self.action(1, tool: "send_slack_message", created: "2026-11-06T09:05:00Z"),
            Self.action(2, tool: "create_track", created: "2026-11-06T09:10:00Z"),
            Self.reminder(3, created: "2026-11-06T08:00:00Z"),
            Self.action(4, tool: "create_track", created: "2026-11-06T09:00:00Z")
        ]
        let groups = NeedsApprovalGroups.build(items)
        XCTAssertEqual(groups.map(\.0), [.reminders, .tracksToCreate, .messages])
        XCTAssertEqual(groups[1].1.map(\.key), ["action:4", "action:2"], "oldest first within a group")
    }

    func testMessagesNeverGetApproveAll() {
        let sends = Self.many("send_slack_message", 3)
        XCTAssertEqual(NeedsApprovalGroups.build(sends).map(\.0), [.messages])
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.messages, sends))
    }

    func testConnectorSendsNeverGetApproveAll() {
        let calls = Self.many(ConnectorCallProposal.tool, 3)
        XCTAssertEqual(NeedsApprovalGroups.build(calls).map(\.0), [.other])
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.other, calls))
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.targets, calls), "a connector call is never a bulk tool")
    }

    func testUnknownToolNeverGetsApproveAll() {
        let unknown = Self.many("a_tool_added_later", 3)
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.other, unknown))
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.confluenceJira, unknown), "allowlist, not denylist")
    }

    func testRemindersNeverGetApproveAll() {
        let reminders = (1...3).map { Self.reminder(Int64($0)) }
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.reminders, reminders))
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.tracksToCreate, reminders))
    }

    func testMixedToolsGetNoApproveAll() {
        let mixed = [Self.action(1, tool: "create_target"), Self.action(2, tool: "update_target"),
                     Self.action(3, tool: "create_target")]
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.targets, mixed))
    }

    func testOneToolGroupGetsApproveAll() {
        let tracks = Self.many("create_track", 3, from: 7)
        XCTAssertEqual(NeedsApprovalGroups.approveAllIDs(.tracksToCreate, tracks), [7, 8, 9])
    }

    func testSingleItemGetsNoApproveAll() {
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.tracksToCreate, Self.many("create_track", 1)))
        let onePending = [Self.action(1, tool: "create_track"),
                          Self.action(2, tool: "create_track", status: "failed")]
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.tracksToCreate, onePending), "one approvable row")
    }

    /// Only rows the owner can approve are planned: a failed row stays on its
    /// card (Try again), a session-applied call never gets bulk approval.
    func testSessionAppliedAreLeftOut() {
        let issues = [Self.action(1, tool: "create_jira_issue"),
                      Self.action(2, tool: "create_jira_issue", status: "failed"),
                      Self.action(3, tool: "create_jira_issue"),
                      Self.action(4, tool: "create_jira_issue")]
        XCTAssertEqual(NeedsApprovalGroups.approveAllIDs(.confluenceJira, issues), [1, 3, 4])
        let sessionCalls = Self.many(ConnectorCallProposal.tool, 3)
        XCTAssertTrue(sessionCalls.allSatisfy {
            if case let .action(action) = $0.record { return action.isSessionApplied }
            return false
        })
        XCTAssertNil(NeedsApprovalGroups.approveAllIDs(.other, sessionCalls))
    }

    func testBulkGroupIsOneListRow() {
        let tracks = Self.many("create_track", 4)
        let rows = NeedsApprovalGroups.listRows(.tracksToCreate, tracks)
        XCTAssertEqual(rows, [.group(.tracksToCreate, tracks)])
        let content = NeedsApprovalGroups.groupContent(.tracksToCreate, tracks, now: Self.now, calendar: Self.utc)
        XCTAssertEqual(content.title, "Create 4 tracks")
        XCTAssertEqual(content.preview, "r · and 3 more")
        XCTAssertEqual(content.meta, "Proposed by the assistant")
        XCTAssertEqual(content.pill, InboxRowPill(count: 4, tone: .needsYou))
        XCTAssertEqual(content.kind, .approval)
        XCTAssertEqual(NeedsApprovalGroups.groupContent(.targets, tracks, now: Self.now, calendar: Self.utc).title,
                       "4 target changes")
        XCTAssertEqual(
            NeedsApprovalGroups.groupContent(.confluenceJira, tracks, now: Self.now, calendar: Self.utc).title,
            "4 Confluence and Jira changes")

        let sends = Self.many("send_slack_message", 3)
        XCTAssertEqual(NeedsApprovalGroups.listRows(.messages, sends), sends.map(NeedsApprovalListRow.item))
    }

    func testApprovalPreviewAndMeta() throws {
        func text(_ args: String) -> String {
            guard case let .action(action) = Self.action(Int64.random(in: 1...1_000_000), tool: "t", args: args).record
            else { return "" }
            return InboxApprovalText.preview(action)
        }
        XCTAssertEqual(text(#"{"title":"T","text":"  Hello\n there  "}"#), "“Hello there”", "text first, collapsed")
        XCTAssertEqual(text(#"{"message":"","body":"B","comment":"C"}"#), "“B”", "an empty value is skipped")
        XCTAssertEqual(text(#"{"comment":"C","title":"T"}"#), "“C”")
        XCTAssertEqual(text(#"{"title":"T"}"#), "“T”")
        XCTAssertEqual(text(#"{"channel":"C1"}"#), "")
        let long = String(repeating: "a", count: 200)
        let capped = text(#"{"text":"\#(long)"}"#)
        XCTAssertEqual(capped, "“" + String(repeating: "a", count: 139) + "…”")

        func meta(surface: String = "main", context: String = "") -> String {
            guard case let .action(action) = Self.action(1, tool: "t", surface: surface, contextType: context).record
            else { return "" }
            return InboxApprovalText.meta(action)
        }
        XCTAssertEqual(meta(surface: "automation", context: "automation_run"), "Proposed by an automation")
        XCTAssertEqual(meta(surface: "inbox"), "Proposed from the Inbox")
        XCTAssertEqual(meta(surface: "chat"), "Proposed in a chat")
        XCTAssertEqual(meta(surface: "workbench"), "Proposed by a workbench session")
        XCTAssertEqual(meta(), "Proposed by the assistant")

        let reminder = NeedsApprovalGroups.itemContent(Self.reminder(4), now: Self.now, calendar: Self.utc)
        XCTAssertEqual(reminder.title, "Answer colleague A")
        XCTAssertEqual(reminder.preview, "Due 09:30")
        XCTAssertEqual(reminder.meta, "Reminder")
    }

    /// The preview is remembered per action, and made again when its args change.
    func testPreviewFollowsArgsChange() {
        let id = Int64.random(in: 2_000_000...3_000_000)
        guard case let .action(first) = Self.action(id, tool: "t", args: #"{"text":"one"}"#).record,
              case let .action(edited) = Self.action(id, tool: "t", args: #"{"text":"two"}"#).record
        else { return XCTFail("actions") }
        XCTAssertEqual(InboxApprovalText.preview(first), "“one”")
        let decodes = AgentAction.argsDecodes.count
        XCTAssertEqual(InboxApprovalText.preview(first), "“one”")
        XCTAssertEqual(AgentAction.argsDecodes.count, decodes, "no decode while the args stay the same")
        XCTAssertEqual(InboxApprovalText.preview(edited), "“two”")
    }
}
