import Foundation
import WatchtowerCore

/// The assistant tabs of ONE target: the conversation list, which tab is
/// active, and one `TargetChatViewModel` per conversation the user has opened.
///
/// The chat VMs are owned here rather than by the view precisely so a turn
/// started in one tab keeps streaming while the operator reads another — and,
/// because the container itself lives in `TargetAssistantCenter` on `AppState`,
/// so it also keeps streaming after the operator leaves the target screen
/// (house rule: async operations survive navigation).
@MainActor
@Observable
final class TargetAssistantViewModel {
    /// Builds the chat VM for one conversation. Injected by tests; production
    /// uses the real `TargetChatViewModel`.
    typealias ChatFactory = (Int64) -> TargetChatViewModel

    /// Title a tab carries until its first user message renames it.
    static let newChatTitle = "New chat"
    /// How much of that first message becomes the tab's title.
    static let titleLimit = 30

    let targetID: Int

    /// Every conversation of this target, oldest first — the tab order.
    private(set) var conversations: [ChatConversation] = []
    private(set) var activeConversationID: Int64?
    /// The chat VM of the active tab. Kept as stored state (never lazily created
    /// inside `body`) so rendering the section has no side effects.
    private(set) var activeChat: TargetChatViewModel?
    private(set) var errorMessage: String?

    /// Forwarded to every chat VM this container owns: an applied action or a
    /// finished turn is activity on the target. Set by the host screen, which
    /// re-derives its next-step staleness badge from it.
    var onTargetActivity: (() -> Void)?

    private let dbManager: DatabaseManager
    private let makeChat: ChatFactory
    private let firstTabTitle: String
    private var chats: [Int64: TargetChatViewModel] = [:]

    init(
        target: Target,
        viewModel: TargetsViewModel,
        dbManager: DatabaseManager,
        chatFactory: ChatFactory? = nil
    ) {
        self.targetID = target.id
        self.dbManager = dbManager
        self.firstTabTitle = "Task: \(String(target.text.prefix(60)))"
        self.makeChat = chatFactory ?? { conversationID in
            TargetChatViewModel(
                target: target,
                viewModel: viewModel,
                dbManager: dbManager,
                conversationID: conversationID
            )
        }
        load()
    }

    // MARK: - Loading

    /// Reads the tab list and selects the conversation the user last worked in —
    /// the row the pre-tabs `fetchByContext` would have returned — so a target
    /// with a single conversation behaves exactly as it did before tabs. A target
    /// that has never been chatted with gets its one tab here, on first use.
    func load() {
        do {
            conversations = try dbManager.dbPool.read { db in
                try ChatConversationQueries.fetchAllByContext(
                    db, type: "target", id: String(targetID)
                )
            }
        } catch {
            // A failed read is "unknown", never "this target has no chats":
            // falling through to the create below would open a duplicate tab and
            // hide the existing ones. The screen offers "Start a chat" instead.
            conversations = []
            errorMessage = "Failed to load chats: \(error.localizedDescription)"
            return
        }
        if let newest = mostRecentlyUpdated() {
            select(newest.id)
        } else {
            createConversation(title: firstTabTitle)
        }
    }

    /// Newest by `updated_at`, ties resolved toward the earlier tab (the list is
    /// already in creation order).
    private func mostRecentlyUpdated() -> ChatConversation? {
        conversations.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return candidate.updatedAt > best.updatedAt ? candidate : best
        }
    }

    // MARK: - Tabs

    func select(_ conversationID: Int64) {
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        activeConversationID = conversationID
        activeChat = chatViewModel(for: conversationID)
    }

    /// The VM for one tab, created on first visit and kept for the container's
    /// lifetime — switching tabs never tears a streaming turn down.
    @discardableResult
    func chatViewModel(for conversationID: Int64) -> TargetChatViewModel {
        if let existing = chats[conversationID] { return existing }
        let chat = makeChat(conversationID)
        chat.onTargetActivity = { [weak self] in self?.onTargetActivity?() }
        chat.onUserMessage = { [weak self] text in
            self?.autoTitle(conversationID: conversationID, from: text)
        }
        chats[conversationID] = chat
        return chat
    }

    /// The VM of a tab the user has already visited, without creating one.
    func loadedChat(_ conversationID: Int64) -> TargetChatViewModel? {
        chats[conversationID]
    }

    /// Whether that tab's agent is mid-turn — drives the chip's working dot.
    func isWorking(_ conversationID: Int64) -> Bool {
        chats[conversationID]?.isStreaming ?? false
    }

    /// Whether ANY of this target's tabs is mid-turn. The center refuses to
    /// evict a container while this is true.
    var isAnyWorking: Bool {
        chats.values.contains { $0.isStreaming }
    }

    /// Opens a fresh tab and makes it active. Titled "New chat" until its first
    /// user message names it.
    @discardableResult
    func newConversation() -> Int64? {
        createConversation(title: Self.newChatTitle)
    }

    @discardableResult
    private func createConversation(title: String) -> Int64? {
        do {
            let conversation = try dbManager.dbPool.write { db in
                try ChatConversationQueries.create(
                    db, title: title, contextType: "target", contextID: String(targetID)
                )
            }
            // Appending keeps the list in creation order — the new tab is newest.
            conversations.append(conversation)
            select(conversation.id)
            return conversation.id
        } catch {
            errorMessage = "Failed to open a new chat: \(error.localizedDescription)"
            return nil
        }
    }

    func rename(_ conversationID: Int64, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              conversations.contains(where: { $0.id == conversationID }) else { return }
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.updateTitle(db, id: conversationID, title: trimmed)
            }
        } catch {
            errorMessage = "Failed to rename the chat: \(error.localizedDescription)"
            return
        }
        reloadConversation(conversationID)
    }

    /// Closes a tab: the conversation AND its messages are deleted. The last
    /// remaining tab cannot be closed — a target always keeps one assistant
    /// thread.
    func close(_ conversationID: Int64) {
        guard conversations.count > 1,
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        // Stop the turn BEFORE the rows go: cancelling persists whatever the
        // assistant had already streamed, and that write must land in the
        // conversation while it still exists (afterwards it would either fail or
        // orphan a row that the delete below can no longer take with it).
        chats[conversationID]?.cancelStream()
        do {
            try dbManager.dbPool.write { db in
                // Messages are deleted explicitly rather than left to the FK
                // cascade: `PRAGMA foreign_keys` is per-connection, so a closed
                // tab must never be able to leave orphaned rows behind.
                try ChatMessageQueries.deleteByConversation(db, conversationID: conversationID)
                try ChatConversationQueries.delete(db, id: conversationID)
            }
        } catch {
            errorMessage = "Failed to close the chat: \(error.localizedDescription)"
            return
        }
        chats[conversationID]?.stop()
        chats[conversationID] = nil
        conversations.remove(at: index)
        if activeConversationID == conversationID {
            let fallback = conversations[min(index, conversations.count - 1)]
            select(fallback.id)
        }
    }

    /// Tears down every tab's VM — the center calls it before dropping this
    /// container so no evicted tab keeps a GRDB observation running. Only ever
    /// called for an idle container (`isAnyWorking == false`).
    func stop() {
        for chat in chats.values { chat.stop() }
        chats.removeAll()
        activeChat = nil
        activeConversationID = nil
    }

    // MARK: - Titling

    /// Names a still-unnamed tab after its first user message. A tab the user
    /// (or an earlier message) already named is left alone.
    private func autoTitle(conversationID: Int64, from text: String) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              Self.isPlaceholderTitle(conversation.title) else { return }
        rename(conversationID, to: Self.autoTitle(from: text))
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == newChatTitle
    }

    /// The first ~30 characters of a message, whitespace collapsed onto one line.
    static func autoTitle(from text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > titleLimit else { return collapsed }
        let head = collapsed.prefix(titleLimit).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    // MARK: - Helpers

    /// Re-reads one row after a write — `ChatConversation` is an immutable
    /// record, so the list is refreshed from the DB rather than patched.
    private func reloadConversation(_ conversationID: Int64) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        do {
            guard let fresh = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByID(db, id: conversationID)
            }) else { return }
            conversations[index] = fresh
        } catch {
            // The write already landed, so this is a stale label, not lost data
            // — and `errorMessage` would not be rendered on this path anyway
            // (the chat screen shows it only when there is no active chat).
            // Heal it by re-reading the list instead; deliberately NOT load(),
            // which would also re-select the newest tab and move the owner off
            // the chat they are reading. If the retry fails too the label stays
            // stale until the next load, which is the honest outcome here.
            refreshConversationList(after: error)
        }
    }

    /// Second chance for `reloadConversation`: re-read every row, no selection
    /// side effects. Logs rather than surfacing, because by this point the
    /// user-visible state is a tab title one revision behind the database.
    private func refreshConversationList(after original: any Error) {
        do {
            conversations = try dbManager.dbPool.read { db in
                try ChatConversationQueries.fetchAllByContext(
                    db, type: "target", id: String(targetID)
                )
            }
        } catch {
            print("TargetAssistant: chat list is stale — row re-read failed (\(original)), list re-read failed (\(error))")
        }
    }
}
