import Foundation
import WatchtowerCore

// MARK: - Wire types
//
// Field names mirror the Go CLI's JSON contract exactly (`cmd/features.go`'s
// featureJSON/subToggleJSON/disableResultJSON) — `features list --json` and
// `features disable <id> --dry-run --json`.

struct FeatureInfo: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let state: String // enabled | disabled | core
    let core: Bool
    let parent: String
    let configKey: String
    let cost: String
    let feedsInto: [String]
    let subToggles: [FeatureSubToggle]

    enum CodingKeys: String, CodingKey {
        case id, title, description, state, core, parent
        case configKey = "config_key", cost
        case feedsInto = "feeds_into", subToggles = "sub_toggles"
    }
}

struct FeatureSubToggle: Codable, Equatable {
    let key, title, description: String
    let enabled: Bool
}

struct FeatureDependents: Codable, Equatable {
    let feature: String
    let dependents: [Dependent]

    struct Dependent: Codable, Equatable {
        let id, title: String
    }
}

/// Envelope for `features list --json` (`{"features": [...]}`) — decode-only
/// plumbing, not part of the wire contract Settings consumes directly.
private struct FeaturesListResponse: Decodable {
    let features: [FeatureInfo]
}

// MARK: - FeatureManagerService

/// Desktop-side manager for Watchtower's product-pillar feature toggles,
/// backed entirely by the `watchtower features` CLI (`internal/features/`,
/// `cmd/features.go`) — no direct config/DB access, so its state is always
/// exactly what the CLI would report.
///
/// UI flow: `load()` populates `features`; toggling a row calls `setPending`
/// (staged, not yet applied); `disabledFeatureIDs` folds `pending` over the
/// last-loaded state so the UI reflects staged changes immediately; a
/// cascade-confirmation dialog (fed by `dependents(of:)`) may add an id to
/// `applyWithDependents` before the user confirms; `apply()` replays every
/// staged change through the CLI as one sequential batch, restarts the
/// daemon once, and reloads.
@MainActor
@Observable
final class FeatureManagerService {
    private(set) var features: [FeatureInfo] = []
    /// Staged, not-yet-applied changes: a feature id, or a sub-toggle's full
    /// config key (e.g. "memory.semantic.enabled"), → desired enabled state.
    var pending: [String: Bool] = [:]
    var loadError: String?
    var isApplying = false
    /// Feature ids the cascade-confirmation dialog has approved disabling
    /// together with their currently-enabled dependents. `apply()` passes
    /// `--with-dependents` for exactly these ids, then clears the set.
    var applyWithDependents: Set<String> = []

    private let runner: CLIRunnerProtocol

    init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    /// Every feature id currently disabled, folding staged `pending` changes
    /// over the last-loaded state (pending always wins).
    var disabledFeatureIDs: Set<String> {
        var ids = Set(features.filter { $0.state == "disabled" }.map(\.id))
        for (id, enabled) in pending {
            if enabled {
                ids.remove(id)
            } else {
                ids.insert(id)
            }
        }
        return ids
    }

    func load() async {
        loadError = nil
        do {
            let data = try await runner.run(args: ["features", "list", "--json"])
            features = try JSONDecoder().decode(FeaturesListResponse.self, from: data).features
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Previews the cascade for disabling `id` (`disable --dry-run --json`)
    /// without writing anything — the input for the Desktop cascade dialog.
    /// The method itself never throws (a dialog needs *a* list to render);
    /// a CLI failure is still surfaced through `loadError` rather than
    /// disappearing silently, and reads as "no dependents" to the caller.
    func dependents(of id: String) async -> [FeatureDependents.Dependent] {
        loadError = nil
        do {
            let data = try await runner.run(args: ["features", "disable", id, "--dry-run", "--json"])
            return try JSONDecoder().decode(FeatureDependents.self, from: data).dependents
        } catch {
            loadError = error.localizedDescription
            return []
        }
    }

    func setPending(_ id: String, enabled: Bool) {
        pending[id] = enabled
    }

    /// Replays every staged `pending` change through the CLI, sequentially
    /// and in a deterministic (sorted-key) order, then restarts the daemon
    /// once and reloads. A key that matches a top-level feature id routes
    /// through `features enable`/`disable`; anything else is treated as a
    /// sub-toggle's config key and routes through `config set <key> <bool>`.
    ///
    /// Each entry is removed from `pending` only once its own CLI call has
    /// actually succeeded — not optimistically up front, and not as one
    /// final bulk clear (the Jira Features screen's per-toggle rollback
    /// precedent, adapted: a "restore the whole batch" rollback would put
    /// an already-applied entry back into `pending`, inviting a redundant
    /// or confusing re-apply). On the first failed call the loop simply
    /// stops: everything already removed stays removed (it is genuinely
    /// live now), and the failed entry plus anything not yet attempted
    /// stays in `pending` for the user to retry.
    func apply(restart: @MainActor () async -> Void) async {
        guard !pending.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }

        let featureIDs = Set(features.map(\.id))
        for id in pending.keys.sorted() {
            guard let enabled = pending[id] else { continue }
            do {
                try await applyOne(id: id, enabled: enabled, isFeature: featureIDs.contains(id))
            } catch {
                loadError = error.localizedDescription
                return
            }
            pending.removeValue(forKey: id)
        }

        applyWithDependents = []
        await restart()
        await load()
    }

    private func applyOne(id: String, enabled: Bool, isFeature: Bool) async throws {
        guard isFeature else {
            _ = try await runner.run(args: ["config", "set", id, enabled ? "true" : "false"])
            return
        }
        var args = ["features", enabled ? "enable" : "disable", id]
        if !enabled && applyWithDependents.contains(id) {
            args.append("--with-dependents")
        }
        _ = try await runner.run(args: args)
    }
}
