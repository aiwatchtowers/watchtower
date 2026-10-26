import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class ChatHistoryViewModel {
    /// Every listed chat of the workspace as last read (standalone, not
    /// archived), each with its panel line (`ChatHistoryQueries.panelRows`),
    /// newest first — the chats waiting for their delete included.
    private var loadedRows: [ChatPanelRow] = []
    /// The quick delete's Undo window (spec 2026-10-26 §5.3); its chat is
    /// hidden from every read the owner sees (`hiddenChatIDs`).
    var pendingDeletes = PendingChatDeletes()
    /// Chats whose DELETE is being written: hidden until it lands, so a
    /// commit never shows the row again for a moment.
    var committingDeletes: Set<Int64> = []
    /// The panel's keyboard cursor (spec §5.4): the highlighted row while
    /// the panel has the keyboard.
    var panelCursor: Int64?
    /// Changing it hands the keyboard to the panel (`requestPanelKeyboard`).
    var panelKeyboardSerial = 0
    /// Retires the chat's session (`ChatViewModel.forget`) when its delete
    /// commits; `AppState.wireChat` points it at the chat view model.
    @ObservationIgnored var forgetConversation: (Int64) -> Void = { _ in }
    /// The Undo window's wait; a seam for tests.
    @ObservationIgnored var deleteSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored var deleteCommitTask: Task<Void, Never>?
    /// The quit commit's bound wait; a seam for tests.
    @ObservationIgnored var quitDeleteSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The chat on screen (or nil: the landing, a project page). Selecting
    /// one marks it read (spec §5.2).
    var selectedConversationID: Int64? {
        didSet {
            if let id = selectedConversationID, id != oldValue { markRead(id) }
        }
    }
    var searchText = ""
    var lastError: String?
    /// All chats or one project's (spec §4), remembered per workspace.
    private(set) var level: ChatPanelLevel
    /// The project switcher's rows as last read (`loadSwitcherSummaries`),
    /// without the live answering counts (`switcherRows`).
    private(set) var switcherSummaries: [ChatProjectSwitcherPresentation.Summary] = []
    /// Why the switcher's read failed; nil once one succeeds.
    private(set) var switcherError: String?
    /// The "▸ N older" group is open; remembered per level and workspace.
    var olderExpanded: Bool {
        didSet { defaults.set(olderExpanded, forKey: olderExpandedKey(level)) }
    }
    /// Injectable for tests; section boundaries are computed against it.
    @ObservationIgnored var now: () -> Date = Date.init
    /// A turn of that conversation is running (the "Answering" state);
    /// `AppState.wireChat` points it at the chat's session pool, whose
    /// observable `clients` a view asking at render time then follows.
    @ObservationIgnored var isAnswering: (Int64) -> Bool = { _ in false }

    private let dbManager: DatabaseManager
    @ObservationIgnored private let defaults: UserDefaults
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending pin write per chat (board #670).
    let pendingWrites = PendingWrites()
    /// `chat_files/` root for post-delete cleanup; nil without an active
    /// workspace, matching `ChatAttachmentStore.defaultRootDir()`.
    private let attachmentsRoot: URL?
    /// Stamps every read of the panel (the observation's too) with its
    /// order and the level generation it started under: an older read never
    /// overwrites a newer one, and one older than the last level change
    /// never sends the level back to All chats (it may predate the
    /// project's row).
    @ObservationIgnored private let readClock = PanelReadClock()
    /// The newest read applied (`PanelReadClock.Stamp.serial`).
    @ObservationIgnored private var appliedReadSerial = 0
    /// The level changed (`selectLevel`, the fallback included); the chat's
    /// landing leaves a project the panel no longer shows (spec §4).
    /// `AppState.wireChat` points it at `ChatViewModel.panelLevelChanged`.
    @ObservationIgnored var onLevelChanged: (ChatPanelLevel) -> Void = { _ in }
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(
        dbManager: DatabaseManager,
        attachmentsRoot: URL? = ChatAttachmentStore.defaultRootDir(),
        defaults: UserDefaults = .standard
    ) {
        self.dbManager = dbManager
        self.attachmentsRoot = attachmentsRoot
        self.defaults = defaults
        let workspace = dbManager.dbPool.path
        let restored = defaults.string(forKey: Self.levelKey(workspace)).flatMap(ChatPanelLevel.init(storageValue:))
        level = restored ?? .all
        olderExpanded = defaults.bool(forKey: Self.olderExpandedKey(restored ?? .all, workspace: workspace))
    }

    // MARK: - Level

    /// Shows All chats or one project's chats, and remembers it.
    func selectLevel(_ newLevel: ChatPanelLevel) {
        readClock.levelChanged()
        guard newLevel != level else { return }
        level = newLevel
        defaults.set(newLevel.storageValue, forKey: Self.levelKey(workspace))
        olderExpanded = defaults.bool(forKey: olderExpandedKey(newLevel))
        onLevelChanged(newLevel)
    }

    private var workspace: String { dbManager.dbPool.path }

    private static func levelKey(_ workspace: String) -> String { "chat.panelLevel.\(workspace)" }

    private static func olderExpandedKey(_ level: ChatPanelLevel, workspace: String) -> String {
        "chat.olderExpanded.\(level.storageValue).\(workspace)"
    }

    private func olderExpandedKey(_ level: ChatPanelLevel) -> String {
        Self.olderExpandedKey(level, workspace: workspace)
    }

    // MARK: - Project switcher

    /// Re-reads the switcher's projects (the popover asks on open).
    func loadSwitcherSummaries() async {
        do {
            let hidden = hiddenChatIDs
            switcherSummaries = try await dbManager.dbPool.read {
                try ChatProjectQueries.switcherSummaries($0, hiding: hidden)
            }
            switcherError = nil
        } catch {
            switcherError = "Could not load projects: \(error.localizedDescription)"
        }
    }

    /// The switcher's projects, latest activity first, with each one's
    /// answering chats counted live; call it at render time so the view
    /// follows the pool.
    var switcherRows: [ChatProjectSwitcherPresentation.Summary] {
        ChatProjectSwitcherPresentation.rows(
            switcherSummaries,
            chats: allRows.map { (id: $0.id, projectID: $0.conversation.projectID) },
            isAnswering: isAnswering
        )
    }

    // MARK: - Rows

    /// Every listed chat of the workspace but the ones waiting for their
    /// delete. The level's `rows` are filtered from it; the project
    /// switcher counts over it.
    var allRows: [ChatPanelRow] {
        let hidden = hiddenChatIDs
        return hidden.isEmpty ? loadedRows : loadedRows.filter { !hidden.contains($0.id) }
    }

    /// A chat's row as last read, hidden or not (the delete's commit
    /// re-checks its state).
    func loadedRow(_ id: Int64) -> ChatPanelRow? {
        loadedRows.first { $0.id == id }
    }

    /// The chats the quick delete hides: pending in the Undo window, or
    /// being deleted.
    var hiddenChatIDs: Set<Int64> { pendingDeletes.ids.union(committingDeletes) }

    /// The level's chats, newest first.
    var rows: [ChatPanelRow] {
        guard level != .all else { return allRows }
        return allRows.filter { level.lists(projectID: $0.conversation.projectID) }
    }

    /// Every listed chat as a conversation (pin, the landing's recents).
    var conversations: [ChatConversation] { allRows.map(\.conversation) }

    /// The panel's groups: PINNED, RECENT, OLDER (the last one folded unless
    /// `olderExpanded`; its items are all there either way). A chat with
    /// neither a message nor an unsent file (the Chat landing's draft, an
    /// untouched project chat) is listed only while it is the one selected,
    /// i.e. on screen.
    var sections: [ChatHistorySection<ChatPanelRow>] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = rows.filter { row in
            let conv = row.conversation
            guard conv.activeLeafMessageID != nil || conv.hasAttachments || conv.id == selectedConversationID else {
                return false
            }
            return query.isEmpty || conv.title.localizedCaseInsensitiveContains(query)
        }
        return ChatHistoryGrouping.group(listed, now: now(), calendar: .current)
    }

    /// The chat on screen when it lives in the folded older group: shown
    /// under the group's header (the sessions panel's pinned row).
    var pinnedOlderRow: ChatPanelRow? {
        guard !olderExpanded, let selectedConversationID else { return nil }
        return sections.first { $0.kind == .older }?.items.first { $0.id == selectedConversationID }
    }

    /// The rows in the order the panel shows them: a folded older group
    /// contributes only its pinned row. ↑/↓ (and ⌘1…⌘9) walk this.
    var visibleRowIDs: [Int64] {
        sections.flatMap { section -> [Int64] in
            guard section.kind == .older, !olderExpanded else { return section.items.map(\.id) }
            return pinnedOlderRow.map { [$0.id] } ?? []
        }
    }

    /// The row's state dot and line 2 (spec §5.2), answering read live.
    func state(of row: ChatPanelRow) -> ChatPanelRowState {
        ChatPanelRowState(row: row, isAnswering: isAnswering(row.id))
    }

    // MARK: - Read marks

    /// Marks the chat read through its newest complete answer (spec §5.2):
    /// on selection, on entering the tab, and when a turn finishes on the
    /// chat on screen. The row changes only once the mark is written: the
    /// observation (`startObserving`) re-reads it — no read here, since ↑/↓
    /// held down marks one chat per step.
    func markRead(_ id: Int64) {
        writes.start { [weak self] in
            guard let self else { return }
            do {
                try await self.dbManager.dbPool.write { db in try ChatConversationQueries.markRead(db, id: id) }
            } catch {
                NSLog("ChatHistoryViewModel: marking chat %lld read failed: %@", id, error.localizedDescription)
            }
        }
    }

    /// Returns once every write queued so far has landed (tests: a
    /// selection queues its read mark).
    func writesSettled() async {
        await writes.idle()
    }

    func rename(_ id: Int64, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await mutate { db in try ChatConversationQueries.rename(db, id: id, title: String(trimmed.prefix(120))) }
    }

    /// A second press while the pin is written does nothing (board #670).
    func togglePin(_ id: Int64) async {
        await pendingWrites.run("pin:\(id)") {
            let pinned = conversations.first { $0.id == id }?.pinned ?? false
            await mutate { db in try ChatConversationQueries.pin(db, id: id, pinned: !pinned) }
        }
    }

    /// The selection clears only once the chat is archived (the view then
    /// shows the landing): no other chat is selected — and so marked read —
    /// without being shown.
    /// - Returns: whether it was archived (`lastError` says why not).
    @discardableResult
    func archive(_ id: Int64) async -> Bool {
        guard await mutate({ db in try ChatConversationQueries.archive(db, id: id) }) else { return false }
        if selectedConversationID == id { selectedConversationID = nil }
        return true
    }

    /// ⌘K. A read failure is reported, not shown as "no results". A chat
    /// waiting for its delete is not found.
    func search(_ query: String) -> [ChatSearchHit] {
        do {
            let hidden = hiddenChatIDs
            return try dbManager.dbPool.read { db in try ChatSearchQueries.search(db, query: query) }
                .filter { !hidden.contains($0.conversationID) }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    private func mutate(_ write: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        do {
            try await chained { db in try write(db) }
            lastError = nil
            reloadSynchronously()
            return true
        } catch {
            // A chat deleted elsewhere leaves the list instead of lingering.
            if error is RowNotFoundError { reloadSynchronously() }
            lastError = error.localizedDescription
            return false
        }
    }

    var filteredConversations: [ChatConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return conversations }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var selectedConversation: ChatConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    /// Re-reads the rows. Besides this process's own writes (which the
    /// observation sees), the panel needs it for what another process
    /// wrote: a proposal of the session's MCP subprocess, a title written
    /// by Go — `AppState.wireChatRefresh` calls it from the chat's
    /// turn-finished and action-awaited signals.
    func reloadRows(completion: (() -> Void)? = nil) {
        let read = PanelSnapshot.reader(readClock)
        Task.detached { [dbManager] in
            let snapshot: PanelSnapshot?
            do {
                snapshot = try await dbManager.dbPool.read(read)
            } catch {
                NSLog("ChatHistoryViewModel: reading the chats failed: %@", error.localizedDescription)
                snapshot = nil
            }
            await MainActor.run {
                if let snapshot { self.apply(snapshot) }
                completion?()
            }
        }
    }

    /// Follows this process's writes to the panel's tables (an Approve or
    /// Reject, a turn's messages, a read mark). Idempotent; runs for the
    /// app's life (the view model lives on `AppState`).
    func startObserving() {
        guard observation == nil else { return }
        // Every value is stamped, so none is a duplicate; `apply` leaves equal
        // rows alone.
        let values = ValueObservation.tracking(PanelSnapshot.reader(readClock)).values(in: dbManager.dbPool)
        observation = Task { [weak self] in
            do {
                for try await snapshot in values {
                    guard let self else { return }
                    self.apply(snapshot)
                }
            } catch {
                NSLog("ChatHistoryViewModel: observing the chats failed: %@", error.localizedDescription)
            }
        }
    }

    /// A read older than the last one applied is dropped (the detached
    /// reload and the observation race). One started under the current
    /// level also checks it: a project gone since (deleted or archived)
    /// falls back to All chats. A read older than the last level change
    /// does not.
    private func apply(_ snapshot: PanelSnapshot) {
        guard snapshot.stamp.serial > appliedReadSerial else { return }
        appliedReadSerial = snapshot.stamp.serial
        if loadedRows != snapshot.rows { loadedRows = snapshot.rows }
        guard readClock.isCurrent(snapshot.stamp) else { return }
        let resolved = level.resolved(activeProjectIDs: snapshot.activeProjectIDs)
        if resolved != level { selectLevel(resolved) }
    }

    func createConversation() async -> ChatConversation? {
        do {
            let conv = try await chained { db in
                try ChatConversationQueries.create(db)
            }
            reloadSynchronously()
            selectedConversationID = conv.id
            return conv
        } catch {
            return nil
        }
    }

    func deleteConversation(_ id: Int64) async {
        do {
            try await chained { db in
                try ChatConversationQueries.delete(db, id: id)
            }
            // Rows are already gone by FK cascade; only the files remain.
            if let attachmentsRoot {
                ChatAttachmentStore.removeFiles(for: .conversation(id), rootDir: attachmentsRoot)
            }
            loadedRows.removeAll { $0.id == id }
            // Nothing else is selected (and marked read) in its place.
            if selectedConversationID == id { selectedConversationID = nil }
        } catch {
            // The chat is listed again (its delete's hiding ends with the
            // caller); the panel says why it stayed.
            NSLog("ChatHistoryViewModel: deleting chat %lld failed: %@", id, error.localizedDescription)
            lastError = "Could not delete the chat: \(error.localizedDescription)"
        }
    }

    func updateTitle(_ id: Int64, title: String) async {
        let trimmed = String(title.prefix(80))
        do {
            try await chained { db in
                try ChatConversationQueries.updateTitle(db, id: id, title: trimmed)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    func updateSessionID(_ id: Int64, sessionID: String) async {
        do {
            try await chained { db in
                try ChatConversationQueries.updateSessionID(db, id: id, sessionID: sessionID)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    func touch(_ id: Int64) async {
        do {
            try await chained { db in
                try ChatConversationQueries.touch(db, id: id)
            }
            reloadSynchronously()
        } catch {
            // silently ignore
        }
    }

    private func reloadSynchronously() {
        do {
            apply(try dbManager.dbPool.read(PanelSnapshot.reader(readClock)))
        } catch {
            NSLog("ChatHistoryViewModel: reading the chats failed: %@", error.localizedDescription)
        }
    }

    /// A database write in this view model's chain (board #670): it starts
    /// only once every write asked for before it finished.
    private func chained<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.dbManager.dbPool.write(body) }
    }
}

/// One read of the panel: its rows and which projects still exist (the
/// level's fallback), stamped when it started.
private struct PanelSnapshot: Sendable {
    let stamp: PanelReadClock.Stamp
    let rows: [ChatPanelRow]
    let activeProjectIDs: Set<Int64>

    static func reader(_ clock: PanelReadClock) -> @Sendable (Database) throws -> Self {
        { db in
            let stamp = clock.stamp()
            return Self(
                stamp: stamp,
                rows: try ChatHistoryQueries.panelRows(db, projectID: nil),
                activeProjectIDs: Set(try ChatProjectQueries.fetchActive(db).map(\.id))
            )
        }
    }
}

/// The panel's read order and level generation, shared by the main actor
/// and the database's reader threads (`PanelSnapshot.reader` stamps on
/// the reader at the read's start).
final class PanelReadClock: @unchecked Sendable {
    struct Stamp: Sendable, Equatable {
        /// Increases with every read started.
        let serial: Int
        /// The level generation the read started under.
        let levelGeneration: Int
    }

    private let lock = NSLock()
    private var serial = 0
    private var levelGeneration = 0

    func stamp() -> Stamp {
        lock.lock()
        defer { lock.unlock() }
        serial += 1
        return Stamp(serial: serial, levelGeneration: levelGeneration)
    }

    func levelChanged() {
        lock.lock()
        levelGeneration += 1
        lock.unlock()
    }

    /// The read started under the current level generation.
    func isCurrent(_ stamp: Stamp) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stamp.levelGeneration == levelGeneration
    }
}
