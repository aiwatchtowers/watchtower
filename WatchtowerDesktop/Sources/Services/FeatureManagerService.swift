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
    let tagline: String
    let benefits: [String]
    let icon: String
    let state: String // enabled | disabled | core
    let core: Bool
    let parent: String
    let configKey: String
    let cost: String
    let feedsInto: [String]
    let subToggles: [FeatureSubToggle]

    enum CodingKeys: String, CodingKey {
        case id, title, description, tagline, benefits, icon, state, core, parent
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

    /// Fires with the freshly computed `disabledFeatureIDs` after every
    /// successful `load()` — including the trailing reload inside a fully
    /// successful `apply()`, which calls `load()` as its last step. Wired by
    /// `AppState` to `FeatureVisibilityStore` so sidebar/navigation
    /// visibility stays in sync with the manager; nil by default, so this
    /// type has no knowledge of that store.
    var onDisabledChanged: ((Set<String>) -> Void)?

    private let runner: CLIRunnerProtocol

    init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    /// Every feature id currently disabled, folding staged `pending` changes
    /// over the last-loaded state (pending always wins).
    ///
    /// `pending` is keyed by feature id OR by a sub-toggle's full config key
    /// (e.g. "memory.semantic.enabled"), so only keys that name a real
    /// feature are folded here — otherwise staging a sub-toggle off would
    /// put its config key into a set of FEATURE ids, which the sidebar
    /// filter and tuning-section gates then compare against.
    var disabledFeatureIDs: Set<String> {
        let featureIDs = Set(features.map(\.id))
        var ids = Set(features.filter { $0.state == "disabled" }.map(\.id))
        for (id, enabled) in pending where featureIDs.contains(id) {
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
            onDisabledChanged?(disabledFeatureIDs)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Previews the cascade for disabling `id` (`disable --dry-run --json`)
    /// without writing anything — the input for the Desktop cascade dialog.
    /// The method itself never throws, but it returns nil rather than an
    /// empty list when the CLI call fails, so the caller can tell "asked,
    /// and there are none" apart from "could not ask". Folding the two
    /// together would let a transient CLI failure stage a disable as if the
    /// owner had been shown an empty cascade. The failure is also surfaced
    /// through `loadError` for the UI to render.
    func dependents(of id: String) async -> [FeatureDependents.Dependent]? {
        loadError = nil
        do {
            let data = try await runner.run(args: ["features", "disable", id, "--dry-run", "--json"])
            return try JSONDecoder().decode(FeatureDependents.self, from: data).dependents
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    func setPending(_ id: String, enabled: Bool) {
        pending[id] = enabled
    }

    /// Replays every staged `pending` change through the CLI, sequentially
    /// and in a deterministic (sorted-key) order. A key that matches a
    /// top-level feature id routes through `features enable`/`disable`;
    /// anything else is treated as a sub-toggle's config key and routes
    /// through `config set <key> <bool>`.
    ///
    /// Each entry is removed from `pending` only once its own CLI call has
    /// actually succeeded — not optimistically up front, and not as one
    /// final bulk clear (the Jira Features screen's per-toggle rollback
    /// precedent, adapted: a "restore the whole batch" rollback would put
    /// an already-applied entry back into `pending`, inviting a redundant
    /// or confusing re-apply). On the first failed call the loop stops:
    /// everything already removed stays removed (it is genuinely live
    /// now), and the failed entry plus anything not yet attempted stays in
    /// `pending` for the user to retry.
    ///
    /// `restart()` fires whenever at least one change actually went live —
    /// even from a batch that then failed partway through: the feature
    /// exists to stop unwanted AI/token spend, so a user who successfully
    /// disabled something expects it to stop now, not only after some
    /// later fully-successful apply. `load()` always runs at the end,
    /// success or failure, so `features`/`disabledFeatureIDs` (and
    /// `onDisabledChanged`) never go stale relative to whatever subset of
    /// the batch actually landed.
    func apply(restart: @MainActor () async -> Void) async {
        guard !pending.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }

        let featureIDs = Set(features.map(\.id))
        var appliedCount = 0
        var failure: Error?

        for id in pending.keys.sorted() {
            guard let enabled = pending[id] else { continue }
            do {
                try await applyOne(id: id, enabled: enabled, isFeature: featureIDs.contains(id))
            } catch {
                failure = error
                break
            }
            pending.removeValue(forKey: id)
            appliedCount += 1
        }

        if failure == nil {
            applyWithDependents = []
        }
        if appliedCount > 0 {
            await restart()
        }

        // Always reload, success or failure: a batch that stopped partway
        // through may still have changed real feature state (the calls
        // that succeeded are live), so skipping this on failure would
        // leave `features` stale and make `disabledFeatureIDs` misreport
        // an already-applied change as unchanged.
        await load()
        if let failure {
            // `load()` just cleared loadError (or set its own reload
            // error) — the apply failure is what the user needs to see
            // and retry, so it takes precedence over a quiet successful
            // reload.
            loadError = failure.localizedDescription
        }
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

// MARK: - Production wiring

extension FeatureManagerService {
    /// Production convenience initializer for `AppState`, resolving the CLI
    /// runner the same way `MeetingRecorderCenter`/`DictationCenter` do (a
    /// resolver defaulting to `ProcessCLIRunner.makeDefault()`) so this type
    /// can still be a plain, always-constructed `let` there instead of an
    /// optional gated on DB/launch timing — `FeatureManagerService` has no DB
    /// dependency at all. Falls back to a runner that reports
    /// `.binaryNotFound` through the normal `loadError` path on first use
    /// for the (dev-only) case where no CLI is resolvable. Tests keep using
    /// `init(runner:)` directly with a fake runner.
    convenience init() {
        self.init(runner: ProcessCLIRunner.makeDefault() ?? UnresolvedCLIRunner())
    }
}

/// Always throws `.binaryNotFound` on `run(args:)` — the fallback the
/// parameterless `FeatureManagerService()` convenience initializer uses only
/// when `ProcessCLIRunner.makeDefault()` itself fails to resolve a binary.
private struct UnresolvedCLIRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data {
        throw CLIRunnerError.binaryNotFound
    }
}
