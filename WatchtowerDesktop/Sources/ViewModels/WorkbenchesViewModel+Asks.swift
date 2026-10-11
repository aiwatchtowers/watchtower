import Foundation
import WatchtowerCore

/// Owner asks on the workbench page (spec 2026-10-03 Part 8): the stack,
/// the closed lists, the banner and the notices open an ask here.
extension WorkbenchesViewModel {
    /// Opens `askID` the way a stack row click does: the drawer on it and its
    /// session on screen — shown, never started (a stopped one offers
    /// Resume), so a click never launches an agent. An ask filed outside the
    /// app has no session: its drawer opens at the page's trailing edge.
    /// The drawer opens once the session is on screen (it closes whenever
    /// that session leaves it, `setLayout`). Returns false when the ask is
    /// gone or could not be read. `keepKeyboard` (a switch started from the
    /// keyboard, board #412): the terminal coming on screen does not take
    /// the keyboard.
    @discardableResult
    func showAsk(_ askID: Int64, projectID: Int64, keepKeyboard: Bool = false) async -> Bool {
        if selectedWorkbenchID != projectID { drill(into: projectID) }
        guard let ask = await asks.lookUp(askID: askID, projectID: projectID) else { return false }
        if let sessionID = ask.sessionID {
            if keepKeyboard { terminalCenter?.keepKeyboardOnAttach(sessionID) }
            await revealTerminal(projectID: projectID, sessionID: sessionID)
            // A failed open already reports itself; no drawer beside nothing.
            guard layout(projectID: projectID).visiblePanes.contains(.session(sessionID)) else { return true }
        }
        asks.openDrawer(ask)
        return true
    }

    /// A Quick ask's option tapped or Reply sent, on its banner or stack
    /// card (spec 2026-10-10 Part 9.1–9.2): `OwnerAsksViewModel.answerQuick`,
    /// the drawer's answer path. When this call found the ask withdrawn
    /// meanwhile (E29) nothing is written or typed and its card leaves with
    /// the reload; its drawer opens read-only on the "withdrawn" note only
    /// where it changes no page — its workbench selected, its session's
    /// pane on screen, no drawer open — else the notice alone says so.
    @discardableResult
    func answerQuick(_ ask: OwnerAsk, with answer: OwnerAskAnswer) async -> OwnerAsksViewModel.AnswerResult {
        let result = await asks.answerQuick(ask, with: answer)
        guard result == .notOpen, selectedWorkbenchID == ask.projectID, asks.drawerAskIDs[ask.projectID] == nil,
              let sessionID = ask.sessionID,
              layout(projectID: ask.projectID).visiblePanes.contains(.session(sessionID)) else { return result }
        if let closed = await asks.lookUp(askID: ask.id, projectID: ask.projectID), !closed.isOpen {
            asks.openDrawer(closed)
        }
        return result
    }

    /// An `ask #N` clicked in a session's terminal (board #500): that ask's
    /// drawer, the way a stack row opens it — only for an ask of the
    /// session's own workbench. False, with nothing opened or reported, for
    /// a number naming no ask of it. A failed read is no "no such ask":
    /// `showAsk` reads again and reports what fails in the asks' load error.
    @discardableResult
    func openTerminalAskLink(_ askID: Int64, workbenchID: Int64) async -> Bool {
        do {
            guard try await asks.linkedAsk(askID: askID, projectID: workbenchID) != nil else { return false }
        } catch {
            NSLog("OwnerAsks: ask #%lld link read failed: %@", askID, error.localizedDescription)
        }
        return await showAsk(askID, projectID: workbenchID)
    }

    /// Opens the drawer by itself (board #364) on the oldest open ask of a
    /// session on the selected workbench's screen, when that session holds
    /// an ask the owner has not closed a drawer on — after each read of the
    /// asks and each measurement of a session pane with room
    /// (`sessionPaneMeasured`, which also covers a session put on screen).
    /// Never over a drawer already open, never expanded and only in a pane
    /// measured with room for it beside the terminal (the terminal stays
    /// visible and keeps the keyboard), and never moves the keyboard.
    func openNewAsk(projectID: Int64) {
        guard selectedWorkbenchID == projectID, asks.drawerAskIDs[projectID] == nil else { return }
        let onScreen = Set(layout(projectID: projectID).visiblePanes.compactMap { pane -> Int64? in
            if case let .session(id) = pane, asks.roomySessions.contains(id) { return id }
            return nil
        })
        guard let ask = asks.stack(projectID: projectID).askToOpen(
            sessionsOnScreen: onScreen, dismissed: asks.dismissedAskIDs[projectID] ?? []
        ) else { return }
        asks.drawerExpanded = false
        asks.openDrawer(ask)
    }

    /// A session pane's view measured its width (on appearing and on every
    /// change of whether a drawer fits beside its terminal).
    func sessionPaneMeasured(_ sessionID: Int64, projectID: Int64, fits: Bool) {
        asks.setRoomBeside(fits, sessionID: sessionID)
        if fits { openNewAsk(projectID: projectID) }
    }

    /// Whether an expanded ask drawer covers `sessionID`'s terminal: its own
    /// session's, or every terminal of the page for an ask filed outside the
    /// app. A covered terminal never takes the keyboard (typing into an
    /// agent the owner cannot see, then Return, would submit).
    func isObscured(sessionID: Int64, projectID: Int64) -> Bool {
        guard asks.drawerExpanded, let ask = asks.drawerAsk(projectID: projectID) else { return false }
        return ask.sessionID == nil || ask.sessionID == sessionID
    }

    /// The workbench whose stack A / ⌃⌘A would go to: the one on the page,
    /// drilled into, with an ask waiting; nil otherwise (the key is left
    /// alone, Navigate › Show Waiting for You is off).
    var stackKeyboardWorkbench: Int64? {
        guard hasWorkbenchPage, let projectID = selectedWorkbenchID, drilledWorkbenchID == projectID,
              !asks.stack(projectID: projectID).asks.isEmpty else { return nil }
        return projectID
    }

    /// Whether Navigate › Show Waiting for You acts for `shownID`, the
    /// workbench of the key window (`OpenQuicklyCenter.keyWorkbench`).
    func canShowWaitingStack(shownID: Int64?) -> Bool {
        shownID != nil && stackKeyboardWorkbench == shownID
    }

    /// A on the workbench page with no field focused, or ⌃⌘A from
    /// anywhere in its window (board #412, `OwnerAskKeyMap`): the sessions
    /// panel shown and the oldest card of "Waiting for you" given the
    /// keyboard. False — the key left to the window — when no workbench is
    /// drilled into (the panel's level 1 has no stack) or no ask waits.
    func openStackFromKeyboard() -> Bool {
        guard let projectID = stackKeyboardWorkbench else { return false }
        panelVisible = true
        asks.setDrawerKeysActive(false, projectID: projectID)
        asks.requestStackKeyboard(projectID: projectID)
        return true
    }

    /// An ask opened or switched from the keyboard (J / K in the drawer,
    /// Return on a card, board #412): its terminal coming on screen leaves
    /// the keyboard alone, and the drawer then takes the bare keys.
    func showAskFromKeyboard(_ askID: Int64, projectID: Int64) async {
        guard await showAsk(askID, projectID: projectID, keepKeyboard: true) else { return }
        asks.setDrawerKeysActive(true, projectID: projectID)
    }

    /// The drawer's "k of N ›": the next ask of the stack, switching to its
    /// session when another one filed it.
    func showNextAsk(after askID: Int64, projectID: Int64) async {
        guard let next = asks.stack(projectID: projectID).next(after: askID) else { return }
        await showAsk(next.id, projectID: projectID)
    }
}
