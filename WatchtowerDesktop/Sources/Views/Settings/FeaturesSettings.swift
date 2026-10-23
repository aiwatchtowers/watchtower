import SwiftUI
import WatchtowerCore

/// `apply()` itself never throws (partial-failure detail lives in
/// `service.loadError`/`service.pending`), so `FeaturesSettings` wraps a
/// post-apply failure into a thrown error itself — otherwise
/// `ConfigSaveBar.save()`'s `try await extraSave?()` always falls through to
/// its success path and shows "Saved" even when the CLI replay failed.
private enum FeatureManagerApplyError: LocalizedError {
    case applyFailed(String)

    var errorDescription: String? {
        switch self {
        case .applyFailed(let message): return message
        }
    }
}

/// Features tab — the Feature Manager (on/off toggles + cascade dialog) on
/// top, the pointer to Automations → Built in (Briefing and Day Plan moved
/// there, C2), then per-feature tuning (Digest, Ideas) for whichever of
/// those pillars is currently enabled, plus notification
/// preferences. Save runs the ordinary config.yaml save AND replays any
/// staged Feature Manager changes through the CLI, restarting the daemon
/// once — see `ConfigSaveBar.extraSave`.
struct FeaturesSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService

    var body: some View {
        Form {
            FeatureManagerSection(service: appState.featureManager)
            BuiltinFeaturesPointer {
                appState.navigateToAutomations()
                appState.bringMainWindowForward()
            }
            if slackDigestsEnabled {
                digestSection
            }
            if ideasEnabled {
                ideasSection
            }
            NotificationSettings()
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) {
            ConfigSaveBar(config: config) {
                // Captured before the call: `apply()` is a no-op guarded by
                // `!pending.isEmpty` that returns without touching
                // `loadError` at all when nothing was staged — checking
                // `loadError` unconditionally after the call would risk
                // surfacing a STALE error left over from an earlier, wholly
                // unrelated `dependents(of:)` failure (e.g. the user backed
                // out of a toggle earlier this session) on a Save that never
                // touched the Feature Manager.
                let hadPendingChanges = !appState.featureManager.pending.isEmpty
                await appState.featureManager.apply {
                    // Skipped during the launch's compaction step: the
                    // launch's ensureDaemonRunning picks the new config up.
                    try await appState.restartOnChain(appState.daemonControl)
                }
                // The CLI calls apply() just made are the single writer of
                // the feature on/off keys, so the shared ConfigService
                // snapshot is now stale — reload before anything reads it
                // again. Runs on the failure path too: a batch that stopped
                // partway through still changed real config on disk.
                config.reload()
                if hadPendingChanges, let error = appState.featureManager.loadError {
                    throw FeatureManagerApplyError.applyFailed(error)
                }
            }
        }
    }

    // MARK: - Tuning-section gating
    //
    // A tuning section renders only while its pillar is *effectively*
    // enabled: the last-loaded state XOR any not-yet-saved Feature Manager
    // toggle — so switching a pillar off hides its tuning controls
    // immediately, before Save/restart actually applies the change.

    private var slackDigestsEnabled: Bool {
        !appState.featureManager.disabledFeatureIDs.contains("slack-digests")
    }

    private var ideasEnabled: Bool {
        !appState.featureManager.disabledFeatureIDs.contains("ideas")
    }

    // MARK: - Tuning sections
    //
    // On/off belongs to the Feature Manager section above and to it alone
    // (it is the single writer of every feature key, via the CLI). A tuning
    // section only renders while its pillar is enabled, and holds only
    // tuning controls — `briefingSection` is the shape they all follow.

    private var digestSection: some View {
        Section("Digest") {
            TextField(
                "Min Messages",
                value: Binding(
                    get: { config.digestMinMessages },
                    set: { config.digestMinMessages = $0 }
                ),
                format: .number,
                prompt: Text("5")
            )
        }
    }

    private var ideasSection: some View {
        Section("Ideas") {
            Stepper(
                "Mining interval (hours): \(config.ideasMineIntervalHours)",
                value: $config.ideasMineIntervalHours,
                in: 1...48
            )
            .help("How often the daemon's regular (non-backfill) mining pass runs")
        }
    }
}

/// Settings → Features' row for Briefing and Day Plan, which moved to the
/// Morning brief built-in (spec §5.4): its card turns it on or off and holds
/// its hour and working hours. **Open Automations** goes there.
struct BuiltinFeaturesPointer: View {
    static let line = "These now live in Automations → Built in"

    let onOpen: () -> Void

    var body: some View {
        Section {
            HStack(spacing: Spacing.regular) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text("Briefing and Day Plan")
                    Text(Self.line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Automations", action: onOpen)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
    }
}
