import GRDB
import XCTest
@testable import WatchtowerCore

/// Recipe card or native card, per open approval (spec "Needs approval" →
/// What the Desktop shows): the four conditions, mixed, more than 50, and a
/// closed approval's live artifact never drawn.
final class NeedsApprovalSelectionTests: XCTestCase {
    static func action(
        _ id: Int64,
        created: String = "2026-11-06T09:00:00Z",
        decided: String = "",
        applied: String = "",
        status: String = "pending"
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": id, "tool": "create_jira_issue", "args_json": "{}", "status": status, "surface": "automation",
            "reason": "r", "created_at": created, "decided_at": decided, "applied_at": applied
        ]))
    }

    static func reminder(_ id: Int64, created: String = "2026-11-06T08:00:00Z", due: String) -> Reminder {
        Reminder(row: Row([
            "id": id, "account_id": 1, "message_ref": "", "note": "Answer colleague A", "remind_at": due,
            "status": "pending", "created_at": created
        ]))
    }

    static func artifact(_ key: String, written: String, id: Int64 = 90) -> AutomationOutputCard {
        let at = AutomationDates.parse(written) ?? .distantPast
        return AutomationOutputCard(
            id: id, automationID: 7, automationName: "Needs approval", runID: 3, title: "Approval", body: "",
            priority: "medium", createdAt: at, outputKey: key, writtenAt: at, changedAt: at)
    }

    private func pick(
        _ item: NeedsApprovalItem, _ artifact: AutomationOutputCard?, on: Bool = true, failed: Bool = false
    ) -> NeedsApprovalSelection.Pick {
        NeedsApprovalSelection.pick(approval: item, artifact: artifact, recipeOn: on, lastRunFailed: failed)
    }

    func testRecipeOnlyWhenAllFourHold() {
        let item = NeedsApprovalItem(.action(Self.action(7)))
        let current = Self.artifact("action:7", written: "2026-11-06T09:00:00Z")
        XCTAssertEqual(pick(item, current), .recipe, "written at the approval's change counts as current")
        XCTAssertEqual(pick(item, current, on: false), .native, "recipe off")
        XCTAssertEqual(pick(item, current, failed: true), .native, "last run failed")
        XCTAssertEqual(pick(item, nil), .native, "no artifact yet")
    }

    /// An artifact written before the approval's last change (decided,
    /// applied) is behind: native.
    func testArtifactOlderThanTheApprovalsChangeIsNative() {
        let decided = NeedsApprovalItem(.action(Self.action(7, decided: "2026-11-06T09:30:00Z", status: "failed")))
        XCTAssertEqual(pick(decided, Self.artifact("action:7", written: "2026-11-06T09:10:00Z")), .native)
        XCTAssertEqual(pick(decided, Self.artifact("action:7", written: "2026-11-06T09:31:00Z")), .recipe)
    }

    /// A reminder changes when it comes due (Go `MAX(created_at, remind_at)`).
    func testReminderChangesWhenItComesDue() {
        let item = NeedsApprovalItem(.reminder(Self.reminder(4, due: "2026-11-06T10:00:00Z")))
        XCTAssertEqual(item.key, "reminder:4")
        XCTAssertEqual(item.changedAt, AutomationDates.parse("2026-11-06T10:00:00Z"))
        XCTAssertEqual(pick(item, Self.artifact("reminder:4", written: "2026-11-06T09:59:00Z")), .native)
        XCTAssertEqual(pick(item, Self.artifact("reminder:4", written: "2026-11-06T10:00:00Z")), .recipe)
    }

    func testActionChangedAtIsItsLatestStamp() {
        let item = NeedsApprovalItem(.action(Self.action(
            7, created: "2026-11-06T09:00:00Z", decided: "2026-11-06T09:05:00Z", applied: "2026-11-06T09:06:00Z")))
        XCTAssertEqual(item.key, "action:7")
        XCTAssertEqual(item.changedAt, AutomationDates.parse("2026-11-06T09:06:00Z"))
    }

    /// The run writes the 50 oldest; the rest have no artifact and are drawn
    /// natively, so every open approval is on screen.
    func testMoreThanFiftyFallBackNatively() {
        let actions = (1...60).map { Self.action(Int64($0)) }
        var artifacts: [String: AutomationOutputCard] = [:]
        for id in 1...50 {
            artifacts["action:\(id)"] = Self.artifact("action:\(id)", written: "2026-11-06T09:01:00Z", id: Int64(100 + id))
        }
        let items = NeedsApprovalSelection.items(
            proposals: actions, reminders: [], artifacts: artifacts, recipeOn: true, lastRunFailed: false)
        XCTAssertEqual(items.count, 60)
        XCTAssertEqual(items.filter { $0.recipe != nil }.count, 50)
        XCTAssertEqual(items.filter { $0.recipe == nil }.map(\.ref.id), Array(51...60).map(Int64.init))
    }

    /// Oldest created first, as Go's `openApprovals` orders them (actions
    /// before reminders on a tie, then id), whatever order the read gave.
    func testItemsAreOldestCreatedFirst() {
        let items = NeedsApprovalSelection.items(
            proposals: [Self.action(9, created: "2026-11-06T09:30:00Z"), Self.action(5, created: "2026-11-06T08:00:00Z"),
                        Self.action(4, created: "2026-11-06T08:00:00Z")],
            reminders: [Self.reminder(2, created: "2026-11-06T08:00:00Z", due: "2026-11-06T07:00:00Z"),
                        Self.reminder(1, created: "2026-11-06T09:00:00Z", due: "2026-11-06T06:00:00Z")],
            artifacts: [:], recipeOn: true, lastRunFailed: false)
        XCTAssertEqual(items.map(\.key), ["action:4", "action:5", "reminder:2", "reminder:1", "action:9"])
    }

    /// An artifact whose approval is closed (not in the read's open rows)
    /// is never drawn, whatever the run did.
    func testClosedApprovalWithLiveArtifactIsNotDrawn() {
        let items = NeedsApprovalSelection.items(
            proposals: [Self.action(7)], reminders: [],
            artifacts: ["action:7": Self.artifact("action:7", written: "2026-11-06T09:01:00Z"),
                        "action:8": Self.artifact("action:8", written: "2026-11-06T09:01:00Z", id: 91)],
            recipeOn: true, lastRunFailed: false)
        XCTAssertEqual(items.map(\.key), ["action:7"])
    }

    /// Mixed: a new action drawn natively above the recipe's cards, each
    /// group oldest created first; the notices first.
    func testMixedNativeAboveRecipeNoticesFirst() {
        var feed = InboxFeedSnapshot(
            proposals: [Self.action(7), Self.action(8, created: "2026-11-06T09:20:00Z")],
            reminders: [Self.reminder(4, due: "2026-11-06T09:30:00Z")])
        feed.builtinNotices = [BuiltinUpgradeNotice(builtinID: "morning-brief", error: "kept", updatedAt: Date())]
        let tree = InboxFolderTree(revision: 1, folders: [
            InboxFolder(id: 1, kind: .root, parentID: nil, slug: "inbox", title: "Inbox"),
            InboxFolder(id: 2, kind: .approvals, parentID: 1, slug: "needs-approval", title: "Needs approval")
        ])
        let folders = InboxFolderMenuSnapshot(
            tree: tree, needsApproval: NeedsApprovalState(automationID: 7),
            approvalArtifacts: ["action:7": Self.artifact("action:7", written: "2026-11-06T09:01:00Z"),
                                "reminder:4": Self.artifact("reminder:4", written: "2026-11-06T09:31:00Z", id: 91)],
            openActions: [7, 8])
        let entries = InboxFolderEntries.build(
            folder: tree.folders[1], InboxFolderEntries.Inputs(feed: feed, folders: folders, now: Date()))
        XCTAssertEqual(entries.map(\.id), [
            "notice:morning-brief", "approval:action:8", "approval:reminder:4", "approval:action:7"
        ])
    }
}
