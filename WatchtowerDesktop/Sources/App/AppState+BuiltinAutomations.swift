import Foundation
import WatchtowerCore

/// The built-in automations' writes that live outside their recipe (spec
/// §5.2/§5.4): on/off is the feature keys, the When fields are config.
extension AppState {
    /// A built-in's shipped prompts for its editor chat (`show`'s
    /// `builtin.default_prompts`); none for an owner recipe or when `show`
    /// cannot be read now.
    func builtinDefaultPrompts(_ automation: Automation) async -> [String: String] {
        guard automation.isBuiltin, let vm = automationsViewModel else { return [:] }
        let card = vm.builtinCard(automation)
        if card.detail == nil { await card.load() }
        return card.detail?.defaultPrompts ?? [:]
    }

    /// Automations → Built in with built-in `id`'s card open (an empty
    /// state's "Change the hour"); the tab alone when its row is not listed.
    func openBuiltinAutomation(_ id: String) {
        navigateToAutomations(select: automationsViewModel?.items.first { $0.automation.builtinID == id }?.id)
    }

    /// A built-in's **Turn On** / **Turn Off**: its feature ids through the
    /// feature manager (`features enable` runs the FEAT-03 hook), then one
    /// daemon restart. A Turn On whose features are all on already is the
    /// built-in the daemon stopped after a run that would not end (AUTO-08):
    /// `features enable` of its first feature turns it on again (the CLI
    /// clears the stop; no fast-forward, no restart — the next sync reads
    /// the row). Returns why it did not land, nil on success.
    ///
    /// A Turn On that enabled a feature but whose daemon restart failed also
    /// sets the app-wide daemon banner ("The background sync did not
    /// restart: …" with **Retry**) from the restart's own error (owner's
    /// decision, ask #503): the caller's line may leave once the feature
    /// reads on, yet nothing runs until a restart succeeds. The banner text
    /// never comes from `loadError`, which may hold an enable failure of a
    /// later id instead (`switchNow` keeps the first failure).
    func setBuiltinEnabled(_ featureIDs: [String], on: Bool) async -> String? {
        let daemon = daemonControl
        guard on else {
            let restart: @MainActor () async throws -> Void = { try await self.restartOnChain(daemon) }
            let busy = await featureManager.disableNow(featureIDs, restart: restart).busy
            return busy ? Self.featureChangesBusy : featureManager.loadError
        }
        var restartError: (any Error)?
        let result = await featureManager.enableNow(featureIDs) {
            do {
                try await self.restartOnChain(daemon)
            } catch {
                restartError = error
                throw error
            }
        }
        if let restartError { daemonStartFailure = Self.daemonRestartFailureText(restartError) }
        if result.busy { return Self.featureChangesBusy }
        if let error = featureManager.loadError { return error }
        if result.enabled.isEmpty, let first = featureIDs.first {
            return await featureManager.resumeStoppedBuiltin(first)
        }
        return nil
    }

    /// Needs approval's note **Turn On** (off and stopped): the built-in
    /// card's own Turn On, for its one feature.
    func turnOnNeedsApproval() async -> String? {
        await setBuiltinEnabled([ActionStripViewModel.approvalsFeatureID], on: true)
    }

    /// A built-in card's When **Save**: the config keys written through a
    /// fresh `ConfigService` (only those keys, read just before the write),
    /// then one daemon restart so the next cycle uses them. Outside the
    /// recipe and its hash. `config` is a test seam.
    func saveBuiltinParameters(
        _ values: [String: String],
        config: (@MainActor () -> ConfigService)? = nil
    ) async -> String? {
        do {
            try (config?() ?? ConfigService()).saveBuiltinParameters(values)
        } catch {
            return error.localizedDescription
        }
        do {
            try await restartOnChain(daemonControl)
        } catch {
            return "Saved. Watchtower could not restart to use it: \(error.localizedDescription)"
        }
        return nil
    }
}
