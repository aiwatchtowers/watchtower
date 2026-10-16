import AppKit
import WatchtowerCore

/// The ⌘/ "Ask Watchtower" panel (spec 2026-10-16).
extension AppState {
    func makeAskCenter() -> AskCenter {
        let center = AskCenter(runner: ProcessCLIRunner.makeDefault() ?? UnresolvedCLIRunner())
        center.resolvedLightModel = { [aiModelCatalog] provider in
            aiModelCatalog.provider(provider).flatMap { $0.resolvedLight.isEmpty ? nil : $0.resolvedLight }
        }
        return center
    }

    /// Opens the panel over the main window, fronting it first (from the
    /// Settings or Keyboard Shortcuts window, or tray-only mode). `windows`
    /// and `activate` are test seams.
    func showAskPanel(
        windows: [NSWindow]? = nil,
        activate: () -> Void = ActivationPolicyDecision.becomeRegularAndActivate
    ) {
        bringMainWindowForward(windows: windows, activate: activate)
        isAskPanelShown = true
    }

    /// The sidebar destinations shown right now (feature and source rules),
    /// as the help chat's screens: the panel's **Go to** rows and the only
    /// targets a `watchtower-nav://` link may open.
    var visibleHelpScreens: [HelpScreen] {
        let disabled = featureVisibility.disabledFeatureIDs
        let connected = featureVisibility.connectedSources
        return SidebarDestination.allCases
            .filter { $0.isVisible(disabledFeatures: disabled, connected: connected) }
            .map { HelpScreen(rawValue: $0.rawValue, title: $0.title) }
    }

    /// A `watchtower-nav://<screen>` link from the panel or AI Chat: opens a
    /// visible screen and closes the panel. An unknown or hidden screen is
    /// ignored (the link does nothing).
    func openNavLink(_ url: URL) {
        guard let raw = NavLink.destination(from: url, allowed: Set(visibleHelpScreens.map(\.rawValue))),
              let destination = SidebarDestination(rawValue: raw) else { return }
        selectedDestination = destination
        isAskPanelShown = false
    }
}
