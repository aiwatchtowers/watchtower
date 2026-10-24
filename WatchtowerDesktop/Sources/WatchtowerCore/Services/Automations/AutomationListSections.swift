import Foundation
import GRDB

// MARK: - Draft rows

/// A New automation chat with a draft on disk: listed at the top of its
/// section until it is saved or abandoned.
package struct AutomationDraftRow: Identifiable, Equatable, Sendable {
    package let conversationID: Int64
    /// The conversation's `context_id` (`<draft id>` or `<draft id>-wb<id>`).
    package let contextID: String
    package let workbenchID: Int64?
    package let name: String
    /// The cache file's modification date.
    package let updatedAt: Date

    package var id: Int64 { conversationID }

    package init(conversationID: Int64, contextID: String, workbenchID: Int64?, name: String, updatedAt: Date) {
        self.conversationID = conversationID
        self.contextID = contextID
        self.workbenchID = workbenchID
        self.name = name
        self.updatedAt = updatedAt
    }
}

package enum AutomationDraftRows {
    package static let contextType = "automation_draft"
    package static let untitled = "New automation"

    /// An `automation_draft` conversation, as `conversations` reads it.
    package struct Conversation: Equatable, Sendable {
        package let id: Int64
        package let contextID: String
        package let updatedAt: Date
    }

    /// Every `automation_draft` conversation whose cache file exists and
    /// whose newest line decodes, newest first. A draft of a workbench not in
    /// `liveWorkbenchIDs` (deleted since) is dropped; an unreadable or
    /// undecodable cache is not a row — unless the editor holds the draft
    /// (`openDrafts`, conversation id → name, `AutomationEditorCenter.openNewDraftNames`):
    /// then it is a row named as the editor reads it, dated by its chat.
    package static func load(
        _ db: Database, databasePath: String, liveWorkbenchIDs: Set<Int64>, openDrafts: [Int64: String] = [:]
    ) throws -> [AutomationDraftRow] {
        rows(try conversations(db), databasePath: databasePath, liveWorkbenchIDs: liveWorkbenchIDs,
             openDrafts: openDrafts)
    }

    /// The database half of `load`: the draft conversations, no file read.
    package static func conversations(_ db: Database) throws -> [Conversation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, context_id, updated_at FROM chat_conversations
            WHERE context_type = ? AND context_id IS NOT NULL
            """, arguments: [contextType])
        return rows.map { row in
            Conversation(id: row["id"], contextID: row["context_id"],
                         updatedAt: Date(timeIntervalSince1970: row["updated_at"] ?? 0))
        }
    }

    /// The file half of `load`: reads each conversation's cache file, so it
    /// runs outside a database read.
    package static func rows(
        _ conversations: [Conversation],
        databasePath: String,
        liveWorkbenchIDs: Set<Int64>,
        openDrafts: [Int64: String] = [:]
    ) -> [AutomationDraftRow] {
        var drafts: [AutomationDraftRow] = []
        for conversation in conversations {
            let workbenchID = workbenchID(fromContextID: conversation.contextID)
            if let workbenchID, !liveWorkbenchIDs.contains(workbenchID) { continue }
            let url = AutomationDraftEntry.cacheURL(databasePath: databasePath, conversationID: conversation.id)
            let name: String
            let updatedAt: Date
            if let text = try? String(contentsOf: url, encoding: .utf8),
               case let .entry(entry) = AutomationDraftEntry.newest(inCache: text),
               let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                name = entry.result?.manifest.name ?? ""
                updatedAt = modified
            } else if let open = openDrafts[conversation.id] {
                name = open
                updatedAt = conversation.updatedAt
            } else {
                continue
            }
            drafts.append(AutomationDraftRow(conversationID: conversation.id, contextID: conversation.contextID,
                                             workbenchID: workbenchID, name: name.isEmpty ? untitled : name,
                                             updatedAt: updatedAt))
        }
        return drafts.sorted { ($0.updatedAt, $0.conversationID) > ($1.updatedAt, $1.conversationID) }
    }

    /// The workbench of a draft context id: the `-wb<id>` suffix that
    /// `AutomationEditorChatSurface.draftContextID` appends; nil for personal.
    package static func workbenchID(fromContextID contextID: String) -> Int64? {
        guard let range = contextID.range(of: "-wb", options: .backwards) else { return nil }
        let digits = contextID[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let id = Int64(digits), id > 0 else { return nil }
        return id
    }
}

// MARK: - Sections

/// One section of the list: Built in, Personal, or one workbench.
package struct AutomationListSection: Identifiable, Equatable, Sendable {
    /// "builtin", "personal" or "workbench-<id>".
    package let id: String
    package let title: String
    package let drafts: [AutomationDraftRow]
    package let items: [AutomationListItem]

    /// The section header's count.
    package var count: Int { drafts.count + items.count }
    package var isEmpty: Bool { drafts.isEmpty && items.isEmpty }

    /// What a folded header still says: "1 failed", "1 draft",
    /// "1 needs confirmation", joined by " · "; nil when nothing needs the owner.
    package var attention: String? {
        let failed = items.filter { AutomationRowPresentation.isFailed($0) }.count
        let confirm = items.filter { $0.automation.needsConfirmation }.count
        let parts = [failed > 0 ? "\(failed) failed" : nil,
                     !drafts.isEmpty ? "\(drafts.count) draft" : nil,
                     confirm > 0 ? "\(confirm) needs confirmation" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package init(id: String, title: String, drafts: [AutomationDraftRow], items: [AutomationListItem]) {
        self.id = id
        self.title = title
        self.drafts = drafts
        self.items = items
    }
}

package enum AutomationListSections {
    package static let personalTitle = "Personal"
    package static let builtinTitle = "Built in"

    /// Built in first (every `isBuiltin` item, never in Personal; a built-in
    /// has no drafts), then Personal, then each workbench by name, drafts at the top of
    /// their section. `query` filters items (name or slug) and drafts (name),
    /// ignoring case; a section with nothing left is omitted. A workbench
    /// recipe or draft whose workbench is not in `workbenches` is not shown.
    package static func make(
        items: [AutomationListItem],
        drafts: [AutomationDraftRow],
        workbenches: [(id: Int64, name: String)],
        query: String
    ) -> [AutomationListSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ fields: String...) -> Bool {
            needle.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let shownItems = items.filter { matches($0.automation.name, $0.automation.slug) }
        let shownDrafts = drafts.filter { matches($0.name) }

        var sections: [AutomationListSection] = []
        let builtin = AutomationListSection(
            id: "builtin", title: builtinTitle, drafts: [], items: shownItems.filter(\.automation.isBuiltin)
        )
        if !builtin.isEmpty { sections.append(builtin) }
        let personal = AutomationListSection(
            id: "personal", title: personalTitle,
            drafts: shownDrafts.filter { $0.workbenchID == nil },
            items: shownItems.filter { $0.automation.scope == .personal && !$0.automation.isBuiltin }
        )
        if !personal.isEmpty { sections.append(personal) }

        let ordered = workbenches.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        for workbench in ordered {
            let section = AutomationListSection(
                id: "workbench-\(workbench.id)", title: workbench.name,
                drafts: shownDrafts.filter { $0.workbenchID == workbench.id },
                items: shownItems.filter { $0.automation.scope == .workbench && $0.automation.projectID == workbench.id }
            )
            if !section.isEmpty { sections.append(section) }
        }
        return sections
    }
}

// MARK: - Rows

/// A row's chip. "Disabled" is none: the dot and the "Off · " line say it.
package enum AutomationRowChip: Equatable, Sendable {
    case needsConfirmation, paused, cantRead, draft

    package var title: String {
        switch self {
        case .needsConfirmation: "Needs confirmation"
        case .paused: "Paused"
        case .cantRead: "Can't read"
        case .draft: "Draft"
        }
    }
}

package enum AutomationRowPresentation {
    /// Needs confirmation; Paused for auto-paused grants or a recipe the app
    /// turned off with a reason; Can't read for a parse error.
    package static func chips(_ item: AutomationListItem) -> [AutomationRowChip] {
        // A parse error alone, as the badges have it: nothing else is known.
        if !item.automation.parseError.isEmpty { return [.cantRead] }
        var chips: [AutomationRowChip] = []
        for badge in item.badges {
            switch badge {
            case .needsConfirmation: chips.append(.needsConfirmation)
            case .autoPaused: chips.append(.paused)
            case .parseError, .disabled: break
            }
        }
        if !item.automation.enabled, !item.automation.disabledReason.isEmpty, !chips.contains(.paused) {
            chips.append(.paused)
        }
        return chips
    }

    /// The row's second line; an off recipe's starts "Off · ".
    package static func line(_ item: AutomationListItem, changes: [AutomationChange]?, now: Date) -> String {
        let detail = AutomationCardPresentation.rowDetailLine(item, changes: changes, now: now)
        return isOn(item) ? detail : "Off · " + detail
    }

    /// The row's on/off dot.
    package static func isOn(_ item: AutomationListItem) -> Bool {
        item.automation.enabled
    }

    /// The recipe's one-line summary: the `summary:` key, else the first
    /// sentence of the description.
    package static func summary(_ item: AutomationListItem) -> String? {
        item.automation.parseError.isEmpty ? AutomationRowSummary.summary(recipeText: item.automation.recipeText) : nil
    }

    /// The last run failed (red or orange badge).
    static func isFailed(_ item: AutomationListItem) -> Bool {
        guard let last = item.lastRun else { return false }
        return [.red, .orange].contains(last.status.badge)
    }

    /// The compact right-hand state: chip > failed > off > last run > next run > none.
    package static func state(_ item: AutomationListItem, now: Date) -> AutomationRowState {
        if let chip = chips(item).first { return .chip(chip) }
        if isFailed(item) { return .failed }
        if !isOn(item) { return .off }
        if let last = item.lastRun, let at = last.finishedAt ?? last.startedAt {
            let ago = AutomationCardPresentation.relative(now.timeIntervalSince(at)) + " ago"
            return .lastRun(ok: last.status.badge != .red && last.status.badge != .orange, ago: ago)
        }
        if let next = item.automation.nextRunAt {
            let seconds = next.timeIntervalSince(now)
            return .next(seconds > 0 ? "in " + AutomationCardPresentation.relative(seconds) : "now")
        }
        return .none
    }
}

/// What a compact row shows at its right edge.
package enum AutomationRowState: Equatable, Sendable {
    case chip(AutomationRowChip), failed, off, lastRun(ok: Bool, ago: String), next(String), none
}
