import AppKit

extension AppState {
    /// A phone start with "Bring the window forward" (mobile POC spec §6.5):
    /// the workbench's page on the main window, the app in front — before
    /// the start, so its Work on it placement lands on that page.
    func bringWorkbenchForward(projectID: Int64) {
        selectedDestination = .workbench
        workbenchesViewModel?.drill(into: projectID)
        (NSApp.delegate as? TrayAppDelegate)?.endLoginLaunchClosing()
        ActivationPolicyDecision.becomeRegularAndActivate()
        let shown = NSApp.windows.first { TrayAppDelegate.isMainWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        if let shown {
            if shown.isMiniaturized { shown.deminiaturize(nil) }
            shown.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
