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
        navigateToAutomations(section: .automations)
        guard let vm = automationsViewModel,
              let row = vm.items.first(where: { $0.automation.builtinID == id }) else { return }
        vm.select(row.id)
    }

    /// A built-in's **Turn On** / **Turn Off**: its feature ids through the
    /// feature manager (`features enable` runs the FEAT-03 hook), then one
    /// daemon restart. Returns why it did not land, nil on success.
    func setBuiltinEnabled(_ featureIDs: [String], on: Bool) async -> String? {
        let daemon = daemonControl
        let restart: @MainActor () async throws -> Void = { try await self.restartOnChain(daemon) }
        let busy = on ? await featureManager.enableNow(featureIDs, restart: restart).busy
                      : await featureManager.disableNow(featureIDs, restart: restart).busy
        if busy { return Self.featureChangesBusy }
        return featureManager.loadError
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
