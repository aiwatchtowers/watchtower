import AppKit
import GRDB
import OSLog
import WatchtowerCore

private let automationsLog = Logger(subsystem: Constants.bundleID, category: "automations")

/// Navigation into the Automations tab, and quick run's entry point (spec
/// §12.7): the "Run Automation…" menu item (⌃⌘R) opens the palette here.
/// Every entry that opens something in the panel also switches to the tab
/// (`navigateToAutomations`), so the panel is seen.
extension AppState {
    /// Opens an automation's card, with one run's steps open when given
    /// (a run notification, an Inbox card's label).
    func openAutomationRun(automationID: Int64, runID: Int64?) {
        navigateToAutomations()
        automationsViewModel?.open(automationID: automationID, runID: runID)
    }

    /// **New Automation…** in a workbench's header menu: the Automations
    /// tab opens the New automation panel for that workbench (its scope
    /// fixed, so "What is it for?" is skipped).
    func newAutomation(forWorkbench workbench: Workbench) {
        guard let automationsViewModel else { return }
        automationsViewModel.showNew(AutomationNewFlow(fixedScope: .forWorkbench(workbench)))
        navigateToAutomations()
    }

    /// Opens the Automations tab's editor panel on `target` (an edit, or a
    /// new draft with its start text).
    func openAutomationEditor(_ target: AutomationEditorTarget) {
        guard let automationsViewModel else { return }
        automationsViewModel.showEditor(target)
        navigateToAutomations()
    }

    /// Opens the editor panel on a fresh new draft in `scope` that starts
    /// from `text` (a recipe proposed elsewhere, e.g. an Inbox card): its
    /// column shows every hashed field, and only the owner's press saves.
    func openAutomationDraft(text: String, scope: AutomationScopeChoice) {
        openAutomationEditor(.newDraft(contextID: draftContextID(for: scope), scope: scope, startText: text))
    }

    /// An Inbox proposal card's automation label: opens the run's
    /// automation with the run expanded. A run that is gone (its automation
    /// was deleted) opens nothing; a failed read still opens the tab, where
    /// the list's own read reports what is wrong.
    func openAutomationRun(runID: Int64) {
        guard let pool = databaseManager?.dbPool else { return }
        do {
            guard let automationID = try pool.read({ db in try AutomationQueries.automationID(db, runID: runID) })
            else { return }
            openAutomationRun(automationID: automationID, runID: runID)
        } catch {
            automationsLog.error("opening the automation of run \(runID): \(error.localizedDescription, privacy: .public)")
            selectedDestination = .automations
        }
    }

    /// The Feature Manager has loaded successfully — never the fail-open
    /// empty state before one (R-P5-8). Automations are always on; this only
    /// gates the work they start on their own (the session center, rescans).
    var automationsReady: Bool {
        featureVisibility.isLoaded
    }

    /// "Run Automation…" (⌃⌘R): the same palette whatever tab is selected.
    /// With no main window visible (the Settings window is key, tray-only
    /// mode) one is opened first. `windows` and `activate` are test seams.
    func showRunAutomationPalette(
        windows: [NSWindow]? = nil,
        activate: () -> Void = ActivationPolicyDecision.becomeRegularAndActivate
    ) {
        guard RunAutomationCommand.target(hasCenter: quickRunCenter != nil,
                                          selected: selectedDestination) == .runAutomationPalette else { return }
        bringMainWindowForward(windows: windows, activate: activate)
        quickRunCenter?.lastError = nil
        quickRunCenter?.reload()
        isRunAutomationPaletteShown = true
    }

    /// Fronts the main window, or opens one when none is visible (the
    /// Settings window is key, tray-only mode). Activates either way, like
    /// the tray's Open Watchtower and `bringWorkbenchForward`: a menu-bar
    /// click does not activate the app, so a window behind another app would
    /// otherwise stay there. `windows` and `activate` are test seams; with
    /// no app object or window opener (tests) nothing is opened or activated.
    func bringMainWindowForward(
        windows: [NSWindow]? = nil,
        activate: () -> Void = ActivationPolicyDecision.becomeRegularAndActivate
    ) {
        let shown = (windows ?? NSApp?.windows ?? []).first {
            TrayAppDelegate.isMainWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        if let shown {
            activate()
            if shown.isMiniaturized { shown.deminiaturize(nil) }
            shown.makeKeyAndOrderFront(nil)
        } else if let openMainWindow {
            // A deliberate open: it must win over a still-armed login-launch close.
            (NSApp?.delegate as? TrayAppDelegate)?.endLoginLaunchClosing()
            activate()
            openMainWindow()
        }
    }

    // MARK: - Automation sessions (spec §13.1)

    /// The center launching the sessions automation runs request; a launch
    /// goes through the Workbench view model current at the time.
    func makeAutomationSessionCenter(dbPool: DatabasePool, cliRunner: (any CLIRunnerProtocol)?) -> AutomationSessionCenter {
        let terminals = terminalCenter
        let center = AutomationSessionCenter(
            dbPool: dbPool, cli: AutomationsCLI(runner: cliRunner ?? UnresolvedCLIRunner()),
            start: { [weak self] request in
                guard let vm = self?.workbenchesViewModel else {
                    throw WorkbenchesViewModel.TargetStartError.failed("The Workbench is not ready.")
                }
                return try await vm.startAutomationSession(request)
            },
            isLive: { terminals.liveIDs.contains($0) }
        )
        center.onDisowned = { terminals.dropAutomationRun(sessionIDs: $0) }
        terminals.onRowExit = { [weak center] id in
            Task { await center?.sessionExited(rowID: id) }
        }
        return center
    }

    /// Polls once the features list has loaded successfully; before that
    /// (a failed load leaves it so), requests stay pending (their run waits,
    /// bounded by its pause timeout). Once loaded, the workbench rescans
    /// asked for meanwhile run too.
    func syncAutomationSessionCenter() {
        let ready = automationsReady
        if ready { workbenchesViewModel?.automationsBecameReady() }
        guard let center = automationSessionCenter else { return }
        if ready { center.start() } else { center.stop() }
    }

    // MARK: - Tray "Run automation ▸" (spec §12.7)

    /// The tray's sections: nil hides the submenu (the
    /// database is not open yet). Reads `quickRunCenter.rows`, never the database.
    func trayRunAutomationSections(now: Date = Date()) -> [TrayRunAutomationMenu.Section]? {
        guard let center = quickRunCenter else { return nil }
        return TrayRunAutomationMenu.sections(center.rows, now: now)
    }

    /// A click on a tray item. A runnable row runs (a `confirm: true` one
    /// only after **Run** in an app-modal alert — the tray has no window,
    /// ruling R-P3-16); a row that opens something opens it in a main
    /// window brought forward; a refusal is shown in an alert.
    func runAutomationFromTray(_ automationID: Int64, alerts: TrayAutomationAlerts? = nil) async {
        guard let center = quickRunCenter, let row = center.rows.first(where: { $0.id == automationID }) else { return }
        let alerts = alerts ?? .live
        switch await center.activate(row, origin: .tray) {
        case .started, .coalesced:
            break
        case .askFirst:
            guard alerts.confirmRun(row) else {
                center.cancelConfirm()
                return
            }
            await center.confirmRun()
            // A refusal keeps the pending row (the palette's sheet stays up);
            // the tray has no sheet, so it says why and lets go.
            guard center.pendingConfirm != nil else { return }
            let message = center.lastError ?? "The automation did not start."
            center.cancelConfirm()
            alerts.showRefusal(message)
        case .openedConfirmation, .openedCard, .openedRun:
            // `activate` already opened the card or run in the view model.
            bringMainWindowForward()
            navigateToAutomations()
        case let .refused(message):
            alerts.showRefusal(message)
        }
    }

    /// "Open Automations…" at the end of the submenu.
    func openAutomationsFromTray() {
        bringMainWindowForward()
        selectedDestination = .automations
    }
}

// MARK: - New automation chat

extension AppState {
    /// The panel's chat for a new automation, keyed by an explicit context id
    /// (`draftContextID(for:)`), so each draft keeps its own conversation. A
    /// workbench that is gone opens nothing (never a personal chat in its place).
    func newAutomationEditorChat(contextID: String, scope: AutomationScopeChoice) async throws -> AutomationEditorChat? {
        guard let pool = databaseManager?.dbPool else { return nil }
        var workbench: AutomationEditorChatSurface.NewWorkbench?
        if case let .workbench(id, _, _) = scope {
            guard let project = workbenchesViewModel?.summaries.first(where: { $0.project.id == id })?.project
            else { return nil }
            workbench = (id, project.name, project.folderURL.lastPathComponent)
        }
        let provider = Constants.aiProviderID()
        let conversationID = try await AutomationEditorChatSurface.newConversationID(contextID: contextID, dbPool: pool)
        let box = PanelDraftBox()
        return makeAutomationEditorChat(
            conversationID: conversationID, pool: pool, provider: provider, panelDraftBox: box,
            onSaved: { [weak self] savedID in
                self?.newDraftSavedFromChat(savedID, contextID: contextID, conversationID: conversationID)
            },
            makeSpec: { outcomes in
                AutomationEditorChatSurface.newSpec(
                    provider: provider, contextID: contextID, workbench: workbench, conversationID: conversationID,
                    dbPool: pool, outcomes: outcomes, panelDraft: box.read)
            }
        )
    }

    /// A new draft chat's approved `save_automation` landed: the list is
    /// re-read; a new recipe (`savedID`) unlists the draft, its chat becoming
    /// the automation's (`draftSaved`), and opens its card while the panel
    /// still shows that draft (spec 2026-10-24 §4).
    private func newDraftSavedFromChat(_ savedID: Int64?, contextID: String, conversationID: Int64) {
        guard let vm = automationsViewModel else { return }
        vm.refresh()
        guard let savedID else { return }
        Task {
            await vm.draftSaved(contextID: contextID, conversationID: conversationID, automationID: savedID)
            if case let .editor(.newDraft(current, _, _)) = vm.panel, current == contextID { vm.showCard(savedID) }
        }
    }
}
