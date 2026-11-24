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
        var line = SessionDeliverLine(
            id: "mac-\(UUID().uuidString)", text: text, keepLineBreaks: keepingLineBreaks,
            keepFormat: keepingFormatCharacters, settle: delay, submitIf: false, holdIfPromptText: holdIfPromptText
        )
        let id = line.id
        ownLines[id] = OwnLine(sessionID: sessionID, keysAtStart: ownerKeys[sessionID, default: 0])
        delivering[sessionID, default: 0] += 1
        defer {
            delivering[sessionID, default: 1] -= 1
            if delivering[sessionID] == 0 { delivering[sessionID] = nil }
        }
        // The next delivery replaces the bars of the last one.
        clipboardHints.remove(sessionID)
        dropPasteHint(sessionID)
        answerHints[sessionID] = nil
        let endsInBackslash = Self.lineEndsInBackslash(line)
        if !canSubmit() {
            logWithheld(sessionID, "the session's state, before the paste")
        } else if endsInBackslash {
            // Never asked for, so a host that would still press it (an older
            // v2 one, adopted across an update) leaves the line typed too.
            logWithheld(sessionID, "the line ends in a backslash: a Return would be a line break")
        } else {
            line.submitIf = true
        }
        let outcome = await process.deliver(line) { [weak self] in
            let fresh = await refresh()
            let reply = DeliverCheckReply(
                fresh: fresh, canSubmit: canSubmit(), answersDialog: self?.inputAnswersDialog(sessionID) ?? true
            )
            if !reply.fresh { self?.logWithheld(sessionID, "the state read after the pause failed") }
            return reply
        }
        let sameRun = processes[sessionID] === process
        ownLineReplied(id, sessionID: sessionID, outcome: outcome, sameRun: sameRun, endsInBackslash: endsInBackslash)
        switch outcome {
        case .submitted:
            return .submitted
        case .typed:
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
            if sameRun { pasteHints.insert(sessionID) }
            return .mayBeTyped
        case .noSession:
            return .noSession
        }
    }

    /// The host's reply to the app's own line `id`. A line that sits (or may sit) in the
    /// prompt unsubmitted goes into the mirror from this reply or its `left_typed` event,
    /// whichever came first (an interrupted one's event may never come: its entry goes with
    /// the run, or with a host that names no line); any other outcome ends the entry.
    private func ownLineReplied(
        _ id: String, sessionID: Int64, outcome: DeliverOutcome, sameRun: Bool, endsInBackslash: Bool
    ) {
        switch outcome {
        case .typed where sameRun, .interrupted where sameRun:
            lineLeftTyped(sessionID, id: id, endsInBackslash: endsInBackslash)
        case .typed, .interrupted, .submitted, .held, .noPasteMode, .noSession:
            ownLines[id] = nil
        }
    }

    /// A delivery event of the session's current run (the host's, for any
    /// client's delivery — the app's or the hub's): the pane's bars.
    func deliveryEvent(_ sessionID: Int64, _ event: SessionHostDeliveryEvent) {
        switch event.kind {
        case .pasted:
            if pastedKeys[sessionID] == nil { pastedKeys[sessionID] = ownerKeys[sessionID, default: 0] }
            clipboardHints.remove(sessionID)
            dropPasteHint(sessionID)
        case .leftTyped:
            if event.id == nil {
                // A host before the id: no event will name the app's lines.
                ownLines = ownLines.filter { $0.value.sessionID != sessionID || !$0.value.applied }
            }
            lineLeftTyped(sessionID, id: event.id, endsInBackslash: event.endsInBackslash)
            pastedKeys[sessionID] = nil
            if event.besideText { sharedPrompts.insert(sessionID) }
            // An ask's answer shows its own bar (`answerHints`).
            if answerHints[sessionID] == nil { pasteHints.insert(sessionID) }
        case .submitted:
            pastedKeys[sessionID] = nil
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
        pastedKeys[sessionID] = nil
        ownLines = ownLines.filter { $0.value.sessionID != sessionID }
    }

    /// A line of the app's own may sit in the prompt: only a submit empties it.
    func leaveDraftInexact(_ sessionID: Int64) {
        drafts[sessionID, default: DraftModel()].markInexact()
    }

    /// One of the app's own v2 deliveries (`ownLines`): the owner's key count when it began
    /// and whether its `left_typed` event or its reply already put its line in the mirror.
    struct OwnLine: Equatable {
        let sessionID: Int64
        let keysAtStart: Int
        var applied = false
    }

    /// The host left a line typed, or may have (`DraftModel.hostLeftTyped`), from its
    /// `left_typed` event or, for the app's own line (`id` in `ownLines`), its reply: the first
    /// of the two applies it, the second nothing, in either order. `endsInBackslash`: the line's
    /// own (nil, a host before the flag: unknown). An owner's key since the line's delivery
    /// began (the app's own) or since its `pasted` event (another client's; none known: any)
    /// may have landed after the paste, and the mirror read it without the line before the
    /// cursor: the `\` is then unknown too. Unknown reads as a `\` (a Return holds).
    func lineLeftTyped(_ sessionID: Int64, id: String?, endsInBackslash: Bool?) { // swiftlint:disable:this discouraged_optional_boolean
        let anchor: Int?
        if let id, var own = ownLines[id] {
            guard !own.applied else {
                ownLines[id] = nil
                return
            }
            own.applied = true
            ownLines[id] = own
            anchor = own.keysAtStart
        } else {
            anchor = pastedKeys[sessionID]
        }
        let fresh = anchor == ownerKeys[sessionID, default: 0]
        drafts[sessionID, default: DraftModel()].hostLeftTyped(endingInBackslash: !fresh || (endsInBackslash ?? true))
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

extension TerminalCenter {
    /// The session's terminal prompt line as its screen shows it now (the
    /// cursor's row, the prompt box's borders dropped), for the Workchat's
    /// held line (spec 2026-11-24-workchat-polish §6.3). Display only: the
    /// prompt state is the draft model's. nil without a terminal or a line.
    func promptPreview(sessionID: Int64) -> String? {
        guard let view = processes[sessionID]?.view as? PalettedTerminalView else { return nil }
        return Self.promptPreview(row: view.cursorRowText())
    }

    /// `row` without the prompt box's borders and the spaces around them.
    nonisolated static func promptPreview(row: String) -> String? {
        let border = CharacterSet(charactersIn: "│┃╭╮╰╯─━").union(.whitespaces)
        let text = row.trimmingCharacters(in: border)
        return text.isEmpty ? nil : text
    }
}

extension PalettedTerminalView {
    /// The text of the cursor's screen row.
    func cursorRowText() -> String {
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: terminal.getCursorLocation().y) else { return "" }
        return (0..<line.count).reduce(into: "") { text, col in
            let cell = line[col]
            if cell.getCharacter() != "\u{0}" { text.append(terminal.getCharacter(for: cell)) }
        }
    }
}
