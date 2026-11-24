import AppKit
import WatchtowerCore

/// The app's lines into a session through its host's `Deliver` (PROJ-12) and the
/// Mac's mirror of each session's prompt (`drafts`): the owner's keys, the
/// host's delivery events, and what the app's pre-checks read from them.
extension TerminalCenter {
    /// How a line reached the session.
    enum HandoffDelivery: Equatable {
        /// Pasted, then Return — the host's, or the owner's own during the
        /// pause.
        case submitted
        /// Pasted; the owner presses Return (`pasteHints`).
        case pasted
        /// Bracketed paste was off: on the clipboard (`clipboardHints`).
        case copied
        /// `holdIfPromptText` and the prompt held text: nothing written.
        case held
        /// The host took the line but its connection ended (dropped, or no
        /// answer in time) before it said what it did: the line may be in
        /// the prompt, submitted or not. The pane asks for Return.
        case mayBeTyped
        case noSession
    }

    /// "Hand to Claude Code" (spec 2026-10-02 §9.5) and every line the app
    /// types into a session (PROJ-12, board #379) — through the session
    /// host's `Deliver` (Go hub phase 3, spec §8 p. 4b): the host pastes
    /// `text` as one bracketed paste (a hand-off keeps its line breaks, an
    /// answer line passes `keepingLineBreaks: false`) and writes a Return of
    /// its own only when `canSubmit` held before the paste and, after the
    /// pause (`delay`, nil = the agent profile's `pasteSettle`), its
    /// re-check finds `refresh` succeeded (the caller re-reads the agent
    /// state, its poll may be up to 1 s stale), `canSubmit` still holds and
    /// no permission dialog is up (`inputAnswersDialog`) — and only into the
    /// same process run and a prompt that held nothing before and after the
    /// pause, which the host keeps (`internal/sessionhost/deliver.go`). An
    /// owner's submitting Return in the pause sent the line unless that
    /// re-check failed or shows a dialog. Without bracketed paste the line
    /// goes to the clipboard, nothing typed. The app never writes the line
    /// to the PTY itself; the pane's hints follow the host's delivery
    /// events (`deliveryEvent`). A second delivery while one is in its
    /// pause is only pasted, beside it (the host's pending Return).
    func deliver(
        _ text: String,
        sessionID: Int64,
        keepingLineBreaks: Bool = true,
        keepingFormatCharacters: Bool = false,
        delay: Duration? = nil,
        holdIfPromptText: Bool = false,
        refresh: @escaping @MainActor () async -> Bool = { true },
        submitIf canSubmit: @escaping @MainActor () -> Bool
    ) async -> HandoffDelivery {
        guard states[sessionID] == .running, let process = processes[sessionID] else { return .noSession }
        guard process.hostDelivers else {
            // A v1-only host: typed here, as before v2.
            return await typeLocally(text, sessionID: sessionID, keepingLineBreaks: keepingLineBreaks,
                                     keepingFormatCharacters: keepingFormatCharacters, delay: delay,
                                     refresh: refresh, submitIf: canSubmit)
        }
        let keysAtStart = ownerKeys[sessionID, default: 0]
        delivering[sessionID, default: 0] += 1
        deliveryKeys[sessionID] = deliveryKeys[sessionID] ?? keysAtStart
        defer {
            delivering[sessionID, default: 1] -= 1
            if delivering[sessionID] == 0 { (delivering[sessionID], deliveryKeys[sessionID]) = (nil, nil) }
        }
        // The next delivery replaces the bars of the last one.
        clipboardHints.remove(sessionID)
        dropPasteHint(sessionID)
        answerHints[sessionID] = nil
        let submitIf = canSubmit()
        if !submitIf { logWithheld(sessionID, "the session's state, before the paste") }
        let line = SessionDeliverLine(
            text: text, keepLineBreaks: keepingLineBreaks, keepFormat: keepingFormatCharacters,
            settle: delay, submitIf: submitIf, holdIfPromptText: holdIfPromptText
        )
        let outcome = await process.deliver(line) { [weak self] in
            let fresh = await refresh()
            let reply = DeliverCheckReply(
                fresh: fresh, canSubmit: canSubmit(), answersDialog: self?.inputAnswersDialog(sessionID) ?? true
            )
            if !reply.fresh { self?.logWithheld(sessionID, "the state read after the pause failed") }
            return reply
        }
        switch outcome {
        case .submitted:
            return .submitted
        case .typed:
            // The line sits in the prompt unsubmitted: the app's own
            // pre-checks see it (the host's `left_typed` event says so too).
            if processes[sessionID] === process { hostLeftTyped(sessionID, line, keysAtStart: keysAtStart) }
            return .pasted
        case let .held(reason):
            logWithheld(sessionID, "held by the session host (\(reason))")
            return .held
        case .noPasteMode:
            if case let .clipboard(copy) = WorkbenchCommentPrompt.terminalPayload(
                text, bracketedPaste: false, keepingLineBreaks: keepingLineBreaks,
                keepingFormatCharacters: keepingFormatCharacters
            ) {
                copyToClipboard(copy)
            }
            dropPasteHint(sessionID)
            clipboardHints.insert(sessionID)
            return .copied
        case .interrupted:
            // The host had the line; it may sit in the prompt, Return or
            // not. Never "no session": the owner checks and presses Return.
            logWithheld(sessionID, "the delivery's connection ended before the host answered")
            if processes[sessionID] === process {
                // No `left_typed` event may follow: after the owner's keys the `\` is unknown.
                let known = ownerKeys[sessionID, default: 0] == keysAtStart ? line : nil
                hostLeftTyped(sessionID, known, keysAtStart: keysAtStart)
                pasteHints.insert(sessionID)
            }
            return .mayBeTyped
        case .noSession:
            return .noSession
        }
    }

    /// A delivery event of the session's current run (the host's, for any
    /// client's delivery — the app's or the hub's): the pane's bars.
    func deliveryEvent(_ sessionID: Int64, _ event: SessionHostDeliveryEvent) {
        switch event.kind {
        case .pasted:
            clipboardHints.remove(sessionID)
            dropPasteHint(sessionID)
        case .leftTyped:
            hostLeftTyped(sessionID, nil, keysAtStart: deliveryKeys[sessionID]) // any client's line
            if event.besideText { sharedPrompts.insert(sessionID) }
            // An ask's answer shows its own bar (`answerHints`).
            if answerHints[sessionID] == nil { pasteHints.insert(sessionID) }
        case .submitted:
            break
        }
    }

    /// Sends each live session's host whether a permission dialog is up
    /// (`inputAnswersDialog`), when it changed since the last hint: the
    /// host then counts no dialog key as a draft and withholds a Return
    /// over one (Go `PromptHint`). Called on every read of the states.
    func syncPromptHints() {
        for id in liveIDs {
            guard let process = processes[id] else { continue }
            let dialog = inputAnswersDialog(id)
            guard sentPromptHints[id] != dialog else { continue }
            // Recorded only once sent: a hint the run could not take yet
            // (not bound) goes on the next read.
            if process.sendPromptHint(dialog: dialog) { sentPromptHints[id] = dialog }
        }
    }

    /// Whether the session's prompt holds text not submitted right now, as
    /// the app sees it: the owner's draft, a line the host left typed, or a
    /// line still going to it. The phone's lines are held then (PROJ-16);
    /// the host holds them too (`holdIfPromptText`).
    func promptHoldsText(_ sessionID: Int64) -> Bool {
        if drafts[sessionID]?.holdsText == true || delivering[sessionID] != nil { return true }
        guard let run = runs[sessionID] else { return false }
        return pendingReturns.contains(run)
    }

    /// Why no Return of the app's own was asked for (board #396); the
    /// caller's `canSubmit` logs its own reasons.
    func logWithheld(_ sessionID: Int64, _ reason: String) {
        NSLog("TerminalCenter: session %lld: Return withheld — %@", sessionID, reason)
    }

    func dismissClipboardHint(sessionID: Int64) {
        clipboardHints.remove(sessionID)
        dropPasteHint(sessionID)
        answerHints[sessionID] = nil
    }

    func dropPasteHint(_ sessionID: Int64) {
        pasteHints.remove(sessionID)
        sharedPrompts.remove(sessionID)
    }

    /// The prompt holds nothing not submitted any more.
    func clearPromptDraft(_ sessionID: Int64) {
        drafts[sessionID] = nil
        sharedPrompts.remove(sessionID)
    }

    /// A line of the app's own may sit in the prompt: only a submit empties it.
    func leaveDraftInexact(_ sessionID: Int64) {
        drafts[sessionID, default: DraftModel()].markInexact()
    }

    /// The host left `line` typed, or may have (`DraftModel.hostLeftTyped`). `keysAtStart`: the
    /// owner's key count when the app's delivery began; keys since make the `\` stale. A reply
    /// sets its line's `\` unless stale (then the keys and the event did); a `left_typed` event
    /// (nil, no text) keeps the state during the app's own delivery with no keys since (its
    /// reply has the line), and else makes a `\` possible (another client's line).
    func hostLeftTyped(_ sessionID: Int64, _ line: SessionDeliverLine?, keysAtStart: Int? = nil) {
        let fresh = keysAtStart == ownerKeys[sessionID, default: 0]
        let endsInBackslash = if let line { fresh && Self.lineEndsInBackslash(line) } else { !fresh }
        drafts[sessionID, default: DraftModel()].hostLeftTyped(endingInBackslash: endsInBackslash)
    }

    /// An ask's answer line is waiting in or for a running session: its pane
    /// shows `hint` in place of the clipboard one. Never types anything.
    func showAnswerHint(_ hint: AnswerHint, sessionID: Int64) {
        guard states[sessionID] == .running else { return }
        clipboardHints.remove(sessionID)
        pasteHints.remove(sessionID)
        answerHints[sessionID] = hint
    }

    /// The owner's keys, through the draft model (twin of Go `promptState.ownerInput`;
    /// dialog input changes nothing). A submit in a line's pause sent that line;
    /// any other key but Shift+Tab there reaches the pasted line: inexact. A copied
    /// answer's hint turns into "press Return" (the paste was the first step); a
    /// typed one has done its job; a held one waits for its delivery.
    func ownerInput(_ sessionID: Int64, _ bytes: [UInt8]) {
        // Taken out of `drafts` and compared by its length only, so the run's
        // buffer has one owner and a key appends to it in place, never copies it.
        var draft = drafts.removeValue(forKey: sessionID) ?? DraftModel()
        let before = (draft.count, draft.exact, draft.holdsText)
        let inPause = runs[sessionID].map { pendingReturns.contains($0) && !ownerReturnsInPause.contains($0) } ?? false // line unsent
        let key = draft.feed(bytes, profile: inputProfile(sessionID), dialog: inputAnswersDialog(sessionID))
        switch key {
        case .ignored:
            break
        case .submit:
            sharedPrompts.remove(sessionID)
            if inPause, let run = runs[sessionID] { ownerReturnsInPause.insert(run) }
        case .edit where inPause:
            draft.markInexact()
        case .edit, .neutral:
            break
        }
        drafts[sessionID] = draft == DraftModel() ? nil : draft
        guard key != .ignored else { return }
        ownerKeys[sessionID, default: 0] += 1
        if (draft.count, draft.exact, draft.holdsText) != before { onDraftChanged?(sessionID) }
        switch answerHints[sessionID] {
        case nil, .held?, .stillHeld?, .queued?: break
        case .copied?: answerHints[sessionID] = .typed
        case .typed?: answerHints[sessionID] = nil
        }
    }
}
