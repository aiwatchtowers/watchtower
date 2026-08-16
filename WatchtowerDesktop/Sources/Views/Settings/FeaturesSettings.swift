import SwiftUI
import WatchtowerCore

/// Features tab — the Feature Manager (on/off toggles + cascade dialog) on
/// top, then per-feature tuning (Digest, Briefing, Day Plan, Ideas) for
/// whichever of those pillars is currently enabled, plus notification
/// preferences. Save runs the ordinary config.yaml save AND replays any
/// staged Feature Manager changes through the CLI, restarting the daemon
/// once — see `ConfigSaveBar.extraSave`.
struct FeaturesSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService

    var body: some View {
        Form {
            FeatureManagerSection(service: appState.featureManager)
            if slackDigestsEnabled {
                digestSection
            }
            if briefingEnabled {
                briefingSection
            }
            if dayPlanEnabled {
                dayPlanSection
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
                await appState.featureManager.apply {
                    await DaemonManager.restart()
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

    private var briefingEnabled: Bool {
        !appState.featureManager.disabledFeatureIDs.contains("briefing")
    }

    private var dayPlanEnabled: Bool {
        !appState.featureManager.disabledFeatureIDs.contains("day-plan")
    }

    private var ideasEnabled: Bool {
        !appState.featureManager.disabledFeatureIDs.contains("ideas")
    }

    private var digestSection: some View {
        Section("Digest") {
            Toggle("Enabled", isOn: $config.digestEnabled)

            TextField(
                "Model",
                text: Binding(
                    get: { config.digestModel ?? "" },
                    set: { config.digestModel = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("claude-haiku-4-5-20251001")
            )

            TextField(
                "Min Messages",
                value: Binding(
                    get: { config.digestMinMessages },
                    set: { config.digestMinMessages = $0 }
                ),
                format: .number,
                prompt: Text("5")
            )

            TextField(
                "Language",
                text: Binding(
                    get: { config.digestLanguage ?? "" },
                    set: { config.digestLanguage = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("English")
            )
        }
    }

    private var briefingSection: some View {
        Section("Briefing") {
            Picker(
                "Briefing Hour",
                selection: $config.briefingHour
            ) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            .help("Hour of day when daily briefing should be generated (0-23)")
        }
    }

    private var dayPlanSection: some View {
        Section("Day Plan") {
            Toggle("Enable day plan", isOn: $config.dayPlanEnabled)

            Picker("Generate at hour", selection: $config.dayPlanHour) {
                ForEach(5..<13, id: \.self) { h in
                    Text(String(format: "%02d:00", h)).tag(h)
                }
            }
            .help("Hour of day when the day plan should be generated (5-12)")

            HStack {
                Text("Working hours:")
                TextField(
                    "Start",
                    text: $config.workingHoursStart,
                    prompt: Text("09:00")
                )
                .frame(width: 70)
                Text("–")
                TextField(
                    "End",
                    text: $config.workingHoursEnd,
                    prompt: Text("19:00")
                )
                .frame(width: 70)
            }
            .help("Working window used when scheduling time blocks (HH:MM)")

            Stepper(
                "Max timeblocks: \(config.maxTimeblocks)",
                value: $config.maxTimeblocks,
                in: 1...5
            )
            .help("Maximum number of focused time blocks per day")

            HStack {
                Stepper(
                    "Backlog min: \(config.minBacklog)",
                    value: $config.minBacklog,
                    in: 1...10
                )
                Stepper(
                    "Backlog max: \(config.maxBacklog)",
                    value: $config.maxBacklog,
                    in: 1...15
                )
            }
            .help("Minimum and maximum backlog items shown in the day plan")
        }
    }

    private var ideasSection: some View {
        Section("Ideas") {
            Toggle("Enable ideas registry", isOn: $config.ideasEnabled)
                .help("Mines ideas, notes, and decisions from Slack, meetings, email, and Jira into the Ideas registry")

            Stepper(
                "Mining interval (hours): \(config.ideasMineIntervalHours)",
                value: $config.ideasMineIntervalHours,
                in: 1...48
            )
            .help("How often the daemon's regular (non-backfill) mining pass runs")
        }
    }
}
