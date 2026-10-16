import AppKit
import OSLog
import WatchtowerCore

private let automationsLog = Logger(subsystem: Constants.bundleID, category: "automations")

/// Navigation into the Automations tab, and quick run's entry point (spec
/// §12.7): the "Run Automation…" menu item (⌃⌘R) opens the palette here.
extension AppState {
    /// Opens an automation's card, with one run's steps open when given
    /// (a run notification, an Inbox card's label).
    func openAutomationRun(automationID: Int64, runID: Int64?) {
        selectedDestination = .automations
        automationsViewModel?.open(automationID: automationID, runID: runID)
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

    /// The `automations` feature is on (the Feature Manager's disabled set).
    var isAutomationsFeatureEnabled: Bool {
        !featureVisibility.disabledFeatureIDs.contains("automations")
    }

    /// "Run Automation…" (⌃⌘R): the same palette whatever tab is selected.
    /// With no main window visible (the Settings window is key, tray-only
    /// mode) one is opened first. `windows` and `activate` are test seams.
    func showRunAutomationPalette(
        windows: [NSWindow]? = nil,
        activate: () -> Void = ActivationPolicyDecision.becomeRegularAndActivate
    ) {
        guard RunAutomationCommand.target(featureEnabled: isAutomationsFeatureEnabled,
                                          hasCenter: quickRunCenter != nil,
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

    // MARK: - Tray "Run automation ▸" (spec §12.7)

    /// The tray's sections: nil hides the submenu (feature off, or the
    /// database not open yet). Reads `quickRunCenter.rows`, never the database.
    func trayRunAutomationSections(now: Date = Date()) -> [TrayRunAutomationMenu.Section]? {
        guard isAutomationsFeatureEnabled, let center = quickRunCenter else { return nil }
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
            // `activate` already opened the card, run or sheet in the view model.
            bringMainWindowForward()
            selectedDestination = .automations
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
