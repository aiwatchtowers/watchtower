import AppKit
import WatchtowerCore

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
        let shown = (windows ?? NSApp.windows).first {
            TrayAppDelegate.isMainWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        if let shown {
            if shown.isMiniaturized { shown.deminiaturize(nil) }
            shown.makeKeyAndOrderFront(nil)
        } else {
            activate()
            openMainWindow?()
        }
        quickRunCenter?.lastError = nil
        quickRunCenter?.reload()
        isRunAutomationPaletteShown = true
    }
}
