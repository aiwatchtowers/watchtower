import Foundation

/// A kind of open approval in Needs approval's list (spec "Needs approval",
/// phase 1): what the owner is asked to let happen.
package enum NeedsApprovalGroup: String, CaseIterable, Sendable {
    case messages, tracksToCreate, targets, confluenceJira, reminders, other

    package var title: String {
        switch self {
        case .messages: "Messages"
        case .tracksToCreate: "Tracks to create"
        case .targets: "Targets"
        case .confluenceJira: "Confluence and Jira"
        case .reminders: "Reminders"
        case .other: "Other"
        }
    }

    /// `item`'s group by its tool; a reminder is Reminders, and every tool
    /// not named here (connector calls, Linear writes, `save_automation`,
    /// any tool added later) is Other.
    package static func of(_ item: NeedsApprovalItem) -> Self {
        guard case let .action(action) = item.record else { return .reminders }
        switch action.tool {
        case "send_slack_message", "add_jira_comment", "add_linear_comment":
            return .messages
        case "create_track":
            return .tracksToCreate
        case "create_target", "create_targets", "update_target":
            return .targets
        case "edit_confluence_page", "connect_jira_board", "create_jira_issue", "update_jira_issue",
             "transition_jira_issue", "assign_jira_issue":
            return .confluenceJira
        default:
            return .other
        }
    }
}

/// One row of a group in the list: an approval of its own, or a whole group
/// that **Approve All** covers (as in the mockup).
package enum NeedsApprovalListRow: Equatable, Sendable {
    case item(NeedsApprovalItem)
    case group(NeedsApprovalGroup, [NeedsApprovalItem])
}

/// One block of Needs approval's stack: a header and its cards' entries.
package struct NeedsApprovalStackSection: Identifiable, Equatable, Sendable {
    /// The header's scroll anchor: a group's list row id (`rowID`), else
    /// the list section's id.
    package let id: String
    package let title: String
    /// Nil for the notices and the in-flight rows.
    package let group: NeedsApprovalGroup?
    package let entries: [InboxFolderEntry]
    /// What **Approve All** approves (`approveAllIDs`); nil offers none.
    package let approveAllIDs: [Int64]?

    package init(
        id: String, title: String, group: NeedsApprovalGroup?, entries: [InboxFolderEntry], approveAllIDs: [Int64]?
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.entries = entries
        self.approveAllIDs = approveAllIDs
    }
}

/// Needs approval's groups and **Approve All N…**. Pure.
package enum NeedsApprovalGroups {
    /// The tools **Approve All** may approve together: an allowlist, never a
    /// denylist. None of them sends text to a person; a tool added later is
    /// approved one by one until it is named here.
    package static let bulkTools: Set<String> = [
        "create_track", "create_target", "create_targets", "update_target", "edit_confluence_page",
        "connect_jira_board", "create_jira_issue", "update_jira_issue", "transition_jira_issue",
        "assign_jira_issue"
    ]

    /// The groups that can ever offer **Approve All**.
    private static let bulkGroups: Set<NeedsApprovalGroup> = [.tracksToCreate, .targets, .confluenceJira]

    /// The section ids around the groups.
    package static let noticesSectionID = "notices"
    package static let inFlightSectionID = "inFlight"

    /// `items` by group: groups ordered by their oldest item; inside a
    /// group the native cards (no recipe card) come first, then the
    /// recipe's, each oldest first (`NeedsApprovalItem`'s listed order), so
    /// a new approval shows at once above the recipe's cards (APPROVAL-01);
    /// an empty group is left out.
    package static func build(_ items: [NeedsApprovalItem]) -> [(NeedsApprovalGroup, [NeedsApprovalItem])] {
        var groups: [(NeedsApprovalGroup, [NeedsApprovalItem])] = []
        for item in items.sorted(by: { $0.listedBefore($1) }) {
            let group = NeedsApprovalGroup.of(item)
            if let index = groups.firstIndex(where: { $0.0 == group }) {
                groups[index].1.append(item)
            } else {
                groups.append((group, [item]))
            }
        }
        return groups.map { group, items in
            (group, items.filter { $0.recipe == nil } + items.filter { $0.recipe != nil })
        }
    }

    /// The ids **Approve All** approves, or nil when the group offers none:
    /// only Tracks to create, Targets or Confluence and Jira, every action
    /// of one and the same tool from `bulkTools`, and at least two rows the
    /// owner can approve (pending, not applied by a chat session). Messages,
    /// Reminders and Other never get it.
    package static func approveAllIDs(_ group: NeedsApprovalGroup, _ items: [NeedsApprovalItem]) -> [Int64]? {
        guard bulkGroups.contains(group) else { return nil }
        var actions: [AgentAction] = []
        for item in items {
            guard case let .action(action) = item.record else { return nil }
            actions.append(action)
        }
        let tools = Set(actions.map(\.tool))
        guard tools.count == 1, let tool = tools.first, bulkTools.contains(tool) else { return nil }
        let approvable = actions.filter { $0.isPending && !$0.isSessionApplied }
        return approvable.count >= 2 ? approvable.map(\.id) : nil
    }

    /// A group's list rows: one row for a group **Approve All** covers,
    /// else one row per item.
    package static func listRows(_ group: NeedsApprovalGroup, _ items: [NeedsApprovalItem]) -> [NeedsApprovalListRow] {
        approveAllIDs(group, items) == nil ? items.map(NeedsApprovalListRow.item) : [.group(group, items)]
    }

    /// A group row's list id.
    package static func rowID(_ group: NeedsApprovalGroup) -> String { "group:\(group.rawValue)" }

    /// An open approval: a due reminder, or an action that waits on the
    /// owner (`openActions`). An approved or executing row still in flight
    /// is not.
    package static func isOpen(_ item: NeedsApprovalItem, openActions: Set<Int64>) -> Bool {
        guard case let .action(action) = item.record else { return true }
        return openActions.contains(action.id)
    }

    /// Needs approval's entries split for its list and its stack: the
    /// notices, the open approvals, the in-flight rows.
    private static func split(
        _ entries: [InboxFolderEntry], openActions: Set<Int64>
    ) -> (notices: [InboxFolderEntry], open: [NeedsApprovalItem], inFlight: [InboxFolderEntry]) {
        var notices: [InboxFolderEntry] = []
        var open: [NeedsApprovalItem] = []
        var inFlight: [InboxFolderEntry] = []
        for entry in entries {
            switch entry {
            case .builtinNotice:
                notices.append(entry)
            case let .approval(item) where isOpen(item, openActions: openActions):
                open.append(item)
            case .approval:
                inFlight.append(entry)
            case .artifact, .brief, .legacyDay, .legacyTracks, .legacyIdeas, .legacyMessages:
                continue
            }
        }
        return (notices, open, inFlight)
    }

    /// Needs approval's list sections from its entries: "Built-in updates"
    /// (the notices) first, one section per group holding its `listRows`
    /// (titled by the group, `count` = its approvals), then "Approved, still
    /// running" (in-flight rows). `row` draws an entry's own row.
    package static func sections(
        _ entries: [InboxFolderEntry],
        openActions: Set<Int64>,
        now: Date,
        calendar: Calendar,
        row: (InboxFolderEntry) -> InboxFolderListRow
    ) -> [InboxListSection] {
        let (notices, open, inFlight) = split(entries, openActions: openActions)
        var out: [InboxListSection] = []
        if !notices.isEmpty {
            out.append(InboxListSection(id: noticesSectionID, title: "Built-in updates", rows: notices.map(row)))
        }
        for (group, items) in build(open) {
            let rows = listRows(group, items).map { listRow -> InboxFolderListRow in
                switch listRow {
                case let .item(item):
                    return row(.approval(item))
                case let .group(group, items):
                    return InboxFolderListRow(
                        id: rowID(group), content: groupContent(group, items, now: now, calendar: calendar))
                }
            }
            out.append(InboxListSection(id: group.rawValue, title: group.title, rows: rows, count: items.count))
        }
        if !inFlight.isEmpty {
            out.append(InboxListSection(
                id: inFlightSectionID, title: "Approved, still running", rows: inFlight.map(row)))
        }
        return out
    }

    /// Needs approval's stack of cards in the list's order: the notices,
    /// each group under its header (anchored at the group row's id, with
    /// its **Approve All** ids), the in-flight rows.
    package static func stack(_ entries: [InboxFolderEntry], openActions: Set<Int64>) -> [NeedsApprovalStackSection] {
        let (notices, open, inFlight) = split(entries, openActions: openActions)
        var out: [NeedsApprovalStackSection] = []
        if !notices.isEmpty {
            out.append(NeedsApprovalStackSection(
                id: noticesSectionID, title: "Built-in updates", group: nil, entries: notices, approveAllIDs: nil))
        }
        for (group, items) in build(open) {
            out.append(NeedsApprovalStackSection(
                id: rowID(group), title: group.title, group: group, entries: items.map(InboxFolderEntry.approval),
                approveAllIDs: approveAllIDs(group, items)))
        }
        if !inFlight.isEmpty {
            out.append(NeedsApprovalStackSection(
                id: inFlightSectionID, title: "Approved, still running", group: nil, entries: inFlight,
                approveAllIDs: nil))
        }
        return out
    }

    /// A group row: "Create 4 tracks", the oldest item's title " · and 3
    /// more", its meta, the count on the pill.
    package static func groupContent(
        _ group: NeedsApprovalGroup,
        _ items: [NeedsApprovalItem],
        now: Date,
        calendar: Calendar
    ) -> InboxRowContent {
        let count = items.count
        let title = switch group {
        case .tracksToCreate: "Create \(count) tracks"
        case .targets: "\(count) target changes"
        case .confluenceJira: "\(count) Confluence and Jira changes"
        case .messages, .reminders, .other: "\(count) \(group.title)"
        }
        let oldest = items.min { $0.listedBefore($1) }
        let preview = oldest.map { "\(itemTitle($0)) · and \(count - 1) more" } ?? ""
        var meta = ""
        if case let .action(action)? = oldest?.record { meta = InboxApprovalText.meta(action) }
        return InboxRowContent(
            kind: .approval, title: title, preview: preview, meta: meta,
            time: oldest.flatMap { time($0, now: now, calendar: calendar) } ?? "",
            pill: count > 0 ? InboxRowPill(count: count, tone: .needsYou) : nil, isUnread: true)
    }

    /// One approval's row: an action's reason (else its tool), the args'
    /// text and who proposed it; a reminder's note, when it is due and
    /// "Reminder".
    package static func itemContent(_ item: NeedsApprovalItem, now: Date, calendar: Calendar) -> InboxRowContent {
        let preview: String
        let meta: String
        switch item.record {
        case let .action(action):
            preview = InboxApprovalText.preview(action)
            meta = InboxApprovalText.meta(action)
        case let .reminder(reminder):
            preview = AutomationDates.parse(reminder.remindAt)
                .map { "Due \(InboxRowTime.label($0, now: now, calendar: calendar))" } ?? ""
            meta = "Reminder"
        }
        return InboxRowContent(
            kind: .approval, title: itemTitle(item), preview: preview, meta: meta,
            time: time(item, now: now, calendar: calendar) ?? "", isUnread: true)
    }

    /// An action's reason, else its tool; a reminder's note, else "Reminder".
    package static func itemTitle(_ item: NeedsApprovalItem) -> String {
        switch item.record {
        case let .action(action): action.reason.isEmpty ? action.tool : action.reason
        case let .reminder(reminder): reminder.note.isEmpty ? "Reminder" : reminder.note
        }
    }

    /// When the approval was created, as the list's time.
    private static func time(_ item: NeedsApprovalItem, now: Date, calendar: Calendar) -> String? {
        let stamp = switch item.record {
        case let .action(action): action.createdAt
        case let .reminder(reminder): reminder.createdAt
        }
        return AutomationDates.parse(stamp).map { InboxRowTime.label($0, now: now, calendar: calendar) }
    }
}

/// The words of an approval's row. Pure.
package enum InboxApprovalText {
    /// The longest preview, quotes left out, "…" included.
    package static let previewLimit = 140

    /// The args' text the owner is asked about: the first non-empty string
    /// among `text`, `message`, `body`, `comment`, `title`, whitespace
    /// collapsed, capped at `previewLimit` and quoted; empty with none.
    /// Remembered per action id while its args stay the same: an
    /// `edit_confluence_page` row carries the whole page, and the list is
    /// drawn far more often than its rows change.
    package static func preview(_ action: AgentAction) -> String {
        if let cached = memo.withLock({ $0[action.id] }), cached.args == action.argsJSON { return cached.preview }
        let preview = compose(action)
        memo.withLock { cache in
            if cache.count >= memoLimit { cache.removeAll() }
            cache[action.id] = (action.argsJSON, preview)
        }
        return preview
    }

    /// Who proposed it.
    package static func meta(_ action: AgentAction) -> String {
        if action.contextType == AgentActionFeed.automationRunContext { return "Proposed by an automation" }
        switch action.surface {
        case "inbox": return "Proposed from the Inbox"
        case "chat": return "Proposed in a chat"
        case "workbench": return "Proposed by a workbench session"
        default: return "Proposed by the assistant"
        }
    }

    private static let previewKeys = ["text", "message", "body", "comment", "title"]
    private static let memoLimit = 512
    private static let memo = Memo()

    private static func compose(_ action: AgentAction) -> String {
        let args = action.args
        for key in previewKeys {
            guard let value = args[key] as? String else { continue }
            let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let capped = text.count > previewLimit ? String(text.prefix(previewLimit - 1)) + "…" : text
            return "“\(capped)”"
        }
        return ""
    }

    /// The previews by action id, with the args they were made from.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [Int64: (args: String, preview: String)] = [:]

        func withLock<T>(_ body: (inout [Int64: (args: String, preview: String)]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&cache)
        }
    }
}
