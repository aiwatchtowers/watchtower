import ChatUI
import ChatWire
import Foundation
import Observation
import WatchtowerCore

/// The Chats panel's window state (spec 2026-10-26 §4–§6) over the engine's list (`ChatListModel`): the level (All
/// chats or one project, remembered per workspace), the Pinned / Recent / older sections, the selection, the
/// keyboard cursor, and the quick delete's Undo bar. The list, its writes (pin, rename, move, archive, delete with
/// Undo) and search are the shared model's.
@MainActor
@Observable
final class ChatPanelModel {
    let list: ChatListModel
    /// The chat on screen (nil: the landing or a project page).
    var selectedConversationID: Int64?
    private(set) var level: ChatPanelLevel
    /// The "▸ N older" group is open; remembered per level and workspace.
    var olderExpanded: Bool {
        didSet { defaults.set(olderExpanded, forKey: Self.olderExpandedKey(level, workspace: workspace)) }
    }
    /// The keyboard's row while the panel holds it.
    var panelCursor: Int64?
    /// Bumped to hand the keyboard to the panel.
    private(set) var panelKeyboardSerial = 0
    /// Injectable for tests; the sections' boundaries are computed against it.
    @ObservationIgnored var now: () -> Date = Date.init
    /// The level changed: the chat's landing leaves a project the panel no longer shows.
    @ObservationIgnored var onLevelChanged: (ChatPanelLevel) -> Void = { _ in }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let workspace: String

    init(list: ChatListModel, workspace: String, defaults: UserDefaults = .standard) {
        self.list = list
        self.workspace = workspace
        self.defaults = defaults
        let restored = defaults.string(forKey: Self.levelKey(workspace)).flatMap(ChatPanelLevel.init(storageValue:))
        level = restored ?? .all
        olderExpanded = defaults.bool(forKey: Self.olderExpandedKey(restored ?? .all, workspace: workspace))
    }

    // MARK: - Level

    func selectLevel(_ newLevel: ChatPanelLevel) {
        guard newLevel != level else { return }
        level = newLevel
        defaults.set(newLevel.storageValue, forKey: Self.levelKey(workspace))
        olderExpanded = defaults.bool(forKey: Self.olderExpandedKey(newLevel, workspace: workspace))
        onLevelChanged(newLevel)
    }

    /// The level, All chats once its project is gone (deleted or archived).
    var resolvedLevel: ChatPanelLevel {
        guard let list = list.store.list else { return level }
        return level.resolved(activeProjectIDs: Set(list.projects.map(\.id)))
    }

    private static func levelKey(_ workspace: String) -> String { "chat.panelLevel.\(workspace)" }

    private static func olderExpandedKey(_ level: ChatPanelLevel, workspace: String) -> String {
        "chat.olderExpanded.\(level.storageValue).\(workspace)"
    }

    // MARK: - Rows

    /// The level's chats, without the one waiting in the Undo window.
    var rows: [ChatList.Conversation] {
        let level = resolvedLevel
        return list.conversations.filter { level.lists(projectID: $0.project?.id) }
    }

    var sections: [ChatHistorySection] {
        ChatHistoryGrouping.group(rows, now: now(), calendar: .current)
    }

    /// The folded older group's one row: the chat on screen, when it is there.
    var pinnedOlderRow: ChatList.Conversation? {
        guard let selectedConversationID,
              let older = sections.first(where: { $0.kind == .older }) else { return nil }
        return older.items.first { $0.id == selectedConversationID }
    }

    /// The rows in the order shown (the folded group shows only the chat on screen).
    var visibleRowIDs: [Int64] {
        sections.flatMap { section -> [Int64] in
            guard section.kind == .older, !olderExpanded else { return section.items.map(\.id) }
            return pinnedOlderRow.map { [$0.id] } ?? []
        }
    }

    func row(_ id: Int64) -> ChatList.Conversation? {
        list.store.list?.conversations.first { $0.id == id }
    }

    /// The project switcher's rows, counted from the list.
    var switcherRows: [ChatProjectSwitcherPresentation.Summary] {
        ChatProjectSwitcherPresentation.summaries(list.store.list, hiding: Set([list.pendingDelete].compactMap { $0 }))
    }

    // MARK: - Writes

    /// The ✕ / ⌘⌫ quick delete, with Undo: not while the chat answers or waits for an approval (false: the caller
    /// asks first).
    func deleteWithUndo(_ id: Int64) -> Bool {
        guard let row = row(id), row.state != .answering, row.state != .waiting else { return false }
        movePanelCursorOff(id)
        list.delete(id)
        return true
    }

    /// ⌘Z / Undo: the chat comes back; its id, nil when nothing waited.
    @discardableResult
    func undoPendingDelete() -> Int64? {
        guard let id = list.pendingDelete else { return nil }
        list.undo()
        return id
    }

    /// "Chat “…” deleted" while a quick delete's Undo window runs.
    var pendingDeleteToast: String? {
        guard let id = list.pendingDelete else { return nil }
        let title = row(id)?.title ?? ""
        return title.isEmpty ? ChatListModel.deletedLine : "\(ChatListModel.deletedLine): “\(title)”"
    }

    var lastError: String? { list.notice }

    // MARK: - Keyboard (spec §5.4)

    func requestPanelKeyboard() {
        panelKeyboardSerial += 1
    }

    /// The panel took the keyboard: a cursor no longer shown starts on the chat on screen, else on the first row.
    func enterPanelKeyboard() {
        let visible = visibleRowIDs
        if let panelCursor, visible.contains(panelCursor) { return }
        if let selectedConversationID, visible.contains(selectedConversationID) {
            panelCursor = selectedConversationID
        } else {
            panelCursor = visible.first
        }
    }

    /// ↑ (`step` -1) / ↓ (+1), clamped at the ends.
    func movePanelCursor(_ step: Int) {
        let visible = visibleRowIDs
        guard !visible.isEmpty else { return }
        guard let panelCursor, let index = visible.firstIndex(of: panelCursor) else {
            self.panelCursor = step < 0 ? visible.last : visible.first
            return
        }
        self.panelCursor = visible[min(max(index + step, 0), visible.count - 1)]
    }

    var listedPanelCursor: Int64? {
        guard let panelCursor, visibleRowIDs.contains(panelCursor) else { return nil }
        return panelCursor
    }

    /// ⌘n (View → Go to Item): the n-th row shown; nil past the end.
    func rowID(atShortcut n: Int) -> Int64? {
        let visible = visibleRowIDs
        guard n >= 1, n <= min(visible.count, SessionSwitcherPresentation.maxShortcut) else { return nil }
        return visible[n - 1]
    }

    /// Before the row leaves the panel: the cursor moves to its neighbour, so ⌘⌫ goes on clearing.
    func movePanelCursorOff(_ id: Int64) {
        let visible = visibleRowIDs
        guard panelCursor == id, visible.contains(id) else { return }
        panelCursor = SessionPanelSections.panelNeighbour(of: id, in: visible)
    }
}
