import ChatWire
import Foundation
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// A chat row's swipe and long-press actions (iPhone chat spec §6.2, mockup 1j): Pin or Unpin, Rename, and Delete.
/// The hub deletes at once (`chat_manage delete`), so the Undo is the phone's: Delete hides the row and shows the
/// bar for `undoWindow`, and only when the bar ends does the delete go out. Undo sends nothing. A second Delete
/// while a bar shows ends the first bar at once (its delete goes out).
@MainActor
@Observable
final class ChatRowActions {
    static let undoWindow: Duration = .seconds(5)
    static let undoText = "Chat deleted"
    static let undoAction = "Undo"
    static let failureText = "Couldn't send that. Try again."
    static let deleteRefusedText = "The chat wasn't deleted."

    static let pinTitle = "Pin"
    static let unpinTitle = "Unpin"
    static let renameTitle = "Rename"
    static let deleteTitle = "Delete"
    static let renameSheetTitle = "Rename chat"
    static let renameSave = "Save"
    static let renameCancel = "Cancel"

    /// The chat whose Undo bar shows.
    private(set) var pendingDelete: Int64?
    /// Chats deleted from this phone: kept hidden until the hub's next list drops them.
    private(set) var deleted: Set<Int64> = []
    /// The last action that could not be queued.
    private(set) var failure: String?

    @ObservationIgnored private let sender: ChatSender
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    /// When each hidden chat's delete went out: a refusal queued at or after it brings the row back.
    @ObservationIgnored private var deletedAt: [Int64: Date] = [:]
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ChatRowActions")

    init(sender: ChatSender, sleep: @escaping @Sendable (Duration) async throws -> Void, now: @escaping () -> Date = Date.init) {
        self.sender = sender
        self.sleep = sleep
        self.now = now
    }

    /// The rows the list leaves out: the one under its Undo bar and the ones already deleted.
    var hiddenIDs: Set<Int64> {
        pendingDelete.map { deleted.union([$0]) } ?? deleted
    }

    static func pinActionTitle(pinned: Bool) -> String {
        pinned ? unpinTitle : pinTitle
    }

    func togglePin(_ conversation: ChatList.Conversation) async {
        await send(ChatManageParams(conversationID: conversation.id, op: conversation.pinned ? .unpin : .pin))
    }

    /// The title the hub is sent for `typed`, nil when nothing goes: an empty title is never sent, nor an
    /// unchanged one.
    static func renameTitle(_ typed: String, current: String) -> String? {
        let title = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current else { return nil }
        return title
    }

    func rename(_ conversation: ChatList.Conversation, to typed: String) async {
        guard let title = Self.renameTitle(typed, current: conversation.title) else { return }
        await send(ChatManageParams(conversationID: conversation.id, op: .rename, title: title))
    }

    /// Hides the row and starts its Undo bar; nothing goes to the hub yet.
    func delete(_ id: Int64) {
        if let earlier = pendingDelete { finish(earlier) }
        pendingDelete = id
        failure = nil
        let sleep = sleep
        undoTask = Task { [weak self] in
            do { try await sleep(Self.undoWindow) } catch { return }
            guard !Task.isCancelled else { return }
            self?.finish(id)
        }
    }

    /// The bar's Undo: the row comes back, nothing is sent.
    func undo() {
        undoTask?.cancel()
        undoTask = nil
        pendingDelete = nil
    }

    /// The bar ended: the delete goes out and the row stays hidden.
    private func finish(_ id: Int64) {
        guard pendingDelete == id else { return }
        undoTask?.cancel()
        undoTask = nil
        pendingDelete = nil
        deleted.insert(id)
        deletedAt[id] = now()
        Task { [weak self] in
            guard let self else { return }
            if !(await self.send(ChatManageParams(conversationID: id, op: .delete))) {
                self.deleted.remove(id)
                self.deletedAt[id] = nil
            }
        }
    }

    /// Forgets the hidden ids the hub's list no longer has.
    func prune(keeping ids: Set<Int64>) {
        let gone = deleted.subtracting(ids)
        guard !gone.isEmpty else { return }
        deleted.subtract(gone)
        for id in gone { deletedAt[id] = nil }
    }

    /// The hub refused deletes (`not_found`, `device_not_allowed`, …): a row hidden by a delete sent no later than
    /// the refused one comes back. An older refusal left in the outbox never undoes a newer delete.
    func restoreRefused(_ refused: [Int64: Date]) {
        for (id, queuedAt) in refused {
            guard let sentAt = deletedAt[id], queuedAt >= sentAt else { continue }
            deleted.remove(id)
            deletedAt[id] = nil
            failure = Self.deleteRefusedText
        }
    }

    @discardableResult
    private func send(_ params: ChatManageParams) async -> Bool {
        do {
            try await sender(params)
            failure = nil
            return true
        } catch {
            let kind = String(describing: type(of: error))
            Self.logger.warning("chat_manage \(params.op.rawValue, privacy: .public) not queued: \(kind, privacy: .public)")
            failure = Self.failureText
            return false
        }
    }
}
