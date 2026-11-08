extension AppState {
    /// Every successful Feature Manager load pushes the disabled set into
    /// the visibility store and marks it loaded; a failed one changes nothing.
    func wireFeatureVisibility() {
        featureManager.onDisabledChanged = { [weak self, featureVisibility] ids in
            featureVisibility.disabledFeatureIDs = ids
            featureVisibility.isLoaded = true
            self?.syncAutomationSessionCenter()
            self?.syncPlanUsageFeatureState()
        }
    }

    func syncPlanUsageFeatureState() {
        guard let feature = featureManager.features.first(where: { $0.id == PlanUsageCenter.featureID }) else { return }
        planUsageCenter?.setFeatureEnabled(feature.state != "disabled")
    }
}
