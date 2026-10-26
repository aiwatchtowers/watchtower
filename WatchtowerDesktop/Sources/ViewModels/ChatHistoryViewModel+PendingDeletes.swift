import Foundation
import WatchtowerCore

/// The Chats panel's quick delete with Undo (spec 2026-10-26 §5.3), the
/// sessions panel's deferred delete for chats: a ✕ or ⌘⌫ hides the chat at
/// once and writes nothing; its DELETE — the one deletion path, the session
/// retired (`forgetConversation`) and the files removed
/// (`deleteConversation`) — runs when the Undo window ends, when another
/// delete replaces it, when the panel leaves the screen (the tab is left)
/// or when the app quits. Undo brings the chat back untouched.
extension ChatHistoryViewModel {
    /// The Undo bar's text while a chat waits; nil when nothing is pending.
    var pendingDeleteToast: String? { pendingDeletes.toastText }

    /// Whether `row` is deleted with one ✕ or ⌘⌫, without the alert: not
    /// while it answers or waits for approval (read live).
    func isQuickDelete(_ row: ChatPanelRow) -> Bool {
        state(of: row).allowsQuickDelete
    }

    /// ✕ / ⌘⌫: hides the chat and starts the Undo window; the chat that
    /// was waiting commits now. The cursor moves to the row's neighbour.
    /// False — nothing done — for a chat not listed, or one that answers or
    /// waits for approval (re-checked: it may have turned busy since the ✕
    /// showed); the caller then asks first.
    @discardableResult
    func deleteWithUndo(_ id: Int64) -> Bool {
        guard let row = allRows.first(where: { $0.id == id }), isQuickDelete(row) else { return false }
        movePanelCursorOff(id)
        let replaced = pendingDeletes.enqueue(
            .init(conversationID: id, title: row.conversation.displayTitle), now: now()
        )
        armPendingDeleteCommit()
        if let replaced {
            // Hidden from now on: the commit's task starts a turn later.
            committingDeletes.insert(replaced.conversationID)
            Task { await commitDelete(replaced) }
        }
        return true
    }

    /// Undo: the waiting chat is listed again; nothing was written. Returns
    /// its id, nil with nothing to undo.
    @discardableResult
    func undoPendingDelete() -> Int64? {
        cancelPendingDeleteWindow()
        return pendingDeletes.restore()?.conversationID
    }

    /// Commits the waiting chat now, whatever the window (the panel left
    /// the screen, a confirmed Delete…, the quit). Returns once its DELETE
    /// is written (or failed: the chat is then listed again).
    func commitPendingDelete() async {
        cancelPendingDeleteWindow()
        guard let entry = pendingDeletes.take() else { return }
        await commitDelete(entry)
    }

    /// The quit's commit (PROJ-17's quit step runs beside it): waits for
    /// the chat's DELETE at most `bound`, the session deletes' own bound, so
    /// the two together stay inside it. False when the bound passed first —
    /// the write goes on, and an unfinished one leaves the chat listed at
    /// the next launch.
    func commitPendingDeleteForQuit(
        bound: Duration = .seconds(WorkbenchesViewModel.defaultQuitDeleteWait)
    ) async -> Bool {
        let commit = Task { await commitPendingDelete() }
        let sleep = quitDeleteSleep
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = QuitResumeOnce(continuation)
            let timer = Task { @MainActor in
                await sleep(bound)
                once.resume(false)
            }
            Task { @MainActor in
                await commit.value
                timer.cancel()
                once.resume(true)
            }
        }
        if !finished {
            NSLog("ChatHistoryViewModel: deleting the chat on quit timed out; it is listed again next launch")
        }
        return finished
    }

    /// The DELETE of a chat whose Undo window ended. A chat that answers or
    /// waits for approval by now is never deleted without the alert
    /// (CHAT-01): it is listed again instead.
    private func commitDelete(_ entry: PendingChatDeletes.Entry) async {
        let id = entry.conversationID
        if let row = loadedRow(id), !isQuickDelete(row) {
            committingDeletes.remove(id)
            return
        }
        committingDeletes.insert(id)
        forgetConversation(id)
        await deleteConversation(id)
        committingDeletes.remove(id)
    }

    /// (Re)starts the window for the current deadline; it commits only the
    /// chat it was armed for — a later delete or Undo cancelled it.
    private func armPendingDeleteCommit() {
        cancelPendingDeleteWindow()
        guard let deadline = pendingDeletes.deadline else { return }
        deleteCommitTask = Task { [weak self] in
            guard let sleep = self?.deleteSleep else { return }
            await sleep(.seconds(PendingChatDeletes.window))
            guard let self, !Task.isCancelled, pendingDeletes.deadline == deadline,
                  let entry = pendingDeletes.expired(now: deadline) else { return }
            await commitDelete(entry)
        }
    }

    private func cancelPendingDeleteWindow() {
        deleteCommitTask?.cancel()
        deleteCommitTask = nil
    }
}

/// The Chats panel's keyboard (spec §5.4): while the panel holds it
/// (`SessionsPanelKeyView`), ↑ ↓ move `panelCursor` over the rows shown,
/// Return opens the cursor row, ⌘⌫ deletes it (with Undo, or through the
/// alert while it answers or waits), ⌘Z undoes. Moving the cursor opens
/// nothing.
extension ChatHistoryViewModel {
    /// Hands the keyboard to the panel (a click on its empty space, a
    /// section label, the older header, a ✕, the bar's Undo).
    func requestPanelKeyboard() {
        panelKeyboardSerial += 1
    }

    /// The panel took the keyboard: a cursor no longer shown (or none)
    /// starts on the chat on screen, else on the first row.
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

    /// The cursor, when the panel shows it.
    var listedPanelCursor: Int64? {
        guard let panelCursor, visibleRowIDs.contains(panelCursor) else { return nil }
        return panelCursor
    }

    /// ⌘n (View → Go to Item): the n-th row in the order shown; nil past
    /// the end.
    func rowID(atShortcut n: Int) -> Int64? {
        let visible = visibleRowIDs
        guard n >= 1, n <= min(visible.count, SessionSwitcherPresentation.maxShortcut) else { return nil }
        return visible[n - 1]
    }

    /// Before the row leaves the panel: the cursor moves to its neighbour,
    /// so ⌘⌫ goes on clearing.
    func movePanelCursorOff(_ id: Int64) {
        let visible = visibleRowIDs
        guard panelCursor == id, visible.contains(id) else { return }
        panelCursor = SessionPanelSections.panelNeighbour(of: id, in: visible)
    }
}

/// The first of the quit's two racers (the chat's commit, its bound)
/// resumes; the other is a no-op.
@MainActor
private final class QuitResumeOnce {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
