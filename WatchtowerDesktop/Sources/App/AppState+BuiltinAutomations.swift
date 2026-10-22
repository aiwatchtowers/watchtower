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

    /// A built-in card's When **Save**: each config key written through a
    /// fresh `ConfigService` (read just before the write), then one daemon
    /// restart so the next cycle uses it. Outside the recipe and its hash.
    func saveBuiltinParameters(_ values: [String: String]) async -> String? {
        let config = ConfigService()
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard config.setBuiltinParameter(key, value) else { return "This setting can't be saved here: \(key)" }
        }
        do {
            try config.save()
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
