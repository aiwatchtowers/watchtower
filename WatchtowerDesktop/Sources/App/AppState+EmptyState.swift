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
            dayPlanHour: readinessCenter.dayPlanHour,
            turnOnError: { [weak self] in self?.emptyStateTurnOnError(for: $0) },
            isTurningOn: { [weak self] in self?.turningOnFeatureID == $0 },
            perform: { [weak self] in self?.performEmptyStateAction($0) }
        )
    }

    /// Turn on goes through `turnOnFeatureFromEmptyState`; Connect and Open
    /// Settings open the Settings window on their tab. A tab's own action is
    /// the tab's (`TabEmptyState.onTabAction`).
    func performEmptyStateAction(_ action: EmptyStateAction) {
        switch action {
        case .turnOn(let featureID):
            Task { await turnOnFeatureFromEmptyState(featureID) }
        case .connect:
            settingsTab = .connections
            openSettingsWindow?()
        case .openSettings(let name, _):
            if let tab = SettingsTab(emptyStateTab: name) { settingsTab = tab }
            openSettingsWindow?()
        case .tabAction:
            break
        }
    }
}
