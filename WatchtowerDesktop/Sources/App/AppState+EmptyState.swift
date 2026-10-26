import Foundation
import WatchtowerCore

extension AppState {
    /// The tabs' empty states read readiness, the live sync line, the hours
    /// and the Turn on state from here; read inside a view's body, so the
    /// view follows them.
    var emptyStateContext: EmptyStateContext {
        let syncProgress = daemonManager.syncProgress
        let ownerKnown = owner.isKnown
        return EmptyStateContext(
            readiness: { [readinessCenter] in
                FeatureReadiness.honoringOwner(readinessCenter.readiness(for: $0), of: $0, ownerKnown: ownerKnown)
            },
            syncLine: syncProgress?.isSyncing() == true ? syncProgress?.summary : nil,
            briefingHour: readinessCenter.briefingHour,
            turnOnError: { [weak self] in self?.emptyStateTurnOnError(for: $0) },
            isTurningOn: { [weak self] in self?.turningOnFeatureID == $0 },
            perform: { [weak self] in self?.performEmptyStateAction($0) }
        )
    }

    /// Turn on goes through `turnOnFeatureFromEmptyState`; Connect opens the
    /// Connections tab on the source (Choose Jira boards on Jira, where the
    /// board switches are) and Open Settings the Settings window on its tab;
    /// a built-in's action opens its card in Automations → Built in. A
    /// tab's own action is the tab's (`TabEmptyState.onTabAction`).
    func performEmptyStateAction(_ action: EmptyStateAction) {
        switch action {
        case .turnOn(let featureID):
            Task { await turnOnFeatureFromEmptyState(featureID) }
        case .connect(let source):
            openConnections(ConnectionService(readinessSource: source))
        case .openSettings("connections", _):
            // The services moved to the main window's Connections tab (#899).
            openConnections()
        case .openSettings(let name, _):
            if let tab = SettingsTab(emptyStateTab: name) { settingsTab = tab }
            openSettingsWindow?()
        case .openBuiltin(let id, _):
            openBuiltinAutomation(id)
        case .tabAction:
            break
        }
    }
}
