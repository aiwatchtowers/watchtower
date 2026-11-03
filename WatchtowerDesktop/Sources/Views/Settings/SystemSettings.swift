import SwiftUI
import WatchtowerCore

/// System tab — workspace identity, AI provider, sync cadence, daemon
/// status, storage/data management, log viewer, and app updates.
struct SystemSettings: View {
    @Environment(AppState.self) var appState
    @Environment(\.openWindow) private var openWindow
    @Bindable var config: ConfigService

    var body: some View {
        Form {
            Section("Workspace") {
                LabeledContent("Active Workspace") {
                    Text(config.activeWorkspace ?? "None")
                        .foregroundStyle(.secondary)
                }
            }
            aiSection
            workbenchSection
            syncSection
            DaemonSettings()
            DataSettings()
                .environment(appState)
            PrivacySettings(config: config)
            logsSection
            updateSection
            usageLinkSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) {
            ConfigSaveBar(config: config) {
                // The daemon reads privacy.purge_revoked_data only at startup.
                if config.lastSaveChangedPurge {
                    await appState.accountDaemonPolicy.apply(using: LiveDaemonRestarter())?.value
                    await appState.accountPurgeCenter?.reloadStatus()
                }
                await appState.chatViewModel?.refreshRoutingStatus()
            }
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            TextField(
                "Poll Interval",
                text: Binding(
                    get: { config.syncInterval ?? "" },
                    set: { config.syncInterval = $0 }
                ),
                prompt: Text("15m")
            )
            .help("e.g. 15m, 1h, 30s")

            TextField(
                "Workers",
                value: Binding(
                    get: { config.syncWorkers },
                    set: { config.syncWorkers = $0 }
                ),
                format: .number,
                prompt: Text("1")
            )

            TextField(
                "Initial History Days",
                value: Binding(
                    get: { config.initialHistoryDays },
                    set: { config.initialHistoryDays = $0 }
                ),
                format: .number,
                prompt: Text("30")
            )

            Toggle("Sync Threads", isOn: $config.syncThreads)
        }
    }

    private var aiSection: some View {
        Section("AI") {
            ProviderSettings(config: config, catalog: appState.aiModelCatalog, policy: appState.managedPolicy.policy)
        }
        .task { await appState.aiModelCatalog.load() }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section {
            Button {
                openWindow(id: "logs")
            } label: {
                Label("Open Logs", systemImage: "doc.text")
            }
        }
    }

    // MARK: - Usage Link

    private var usageLinkSection: some View {
        Section {
            Button {
                NSApp.keyWindow?.close()
                appState.selectedDestination = .usage
            } label: {
                Label("View Usage & Pipeline Progress", systemImage: "chart.bar")
            }
        }
    }

    // MARK: - Update Section

    @ViewBuilder
    private var updateSection: some View {
        Section("Update") {
            let service = appState.updateService

            LabeledContent("Current Version") {
                Text(Constants.appVersion)
                    .foregroundStyle(.secondary)
            }

            switch service.state {
            case .idle:
                idleUpdateRow(service: service)

            case .checking:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates...")
                        .foregroundStyle(.secondary)
                }

            case let .available(version, _, _):
                // The notes open in the update window, rendered in full
                // (ask #694), not cut down to a few lines here.
                HStack {
                    Label("Version \(version) available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("What's New…") {
                        _ = service.presentUpdateWindow?()
                    }
                    .buttonStyle(.kitSecondary)
                    Button("Download") {
                        Task { await service.downloadUpdate() }
                    }
                    .buttonStyle(.kitPrimary)
                }

            case .downloading(let progress):
                HStack {
                    ProgressView(value: progress)
                        .frame(maxWidth: 200)
                    Text("Downloading...")
                        .foregroundStyle(.secondary)
                }

            case .readyToInstall:
                readyToInstallRow(service: service)

            case .installing:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing update...")
                        .foregroundStyle(.secondary)
                }

            case .restarting:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Restarting Watchtower...")
                        .foregroundStyle(.secondary)
                }

            case .restartRequired:
                HStack {
                    Label("Update installed — restart Watchtower to finish", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Restart Now") {
                        Task { await service.relaunch() }
                    }
                    .buttonStyle(.kitPrimary)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Update error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await service.checkForUpdates() }
                    }
                }
            }
        }
    }

    /// Install & Restart, disabled under the same gate `UpdateService.install()`
    /// enforces: never swap the bundle under a running capture or transcription.
    private func readyToInstallRow(service: UpdateService) -> some View {
        let busy = appState.meetingRecorderCenter.isBusy
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Ready to install", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Install & Restart") {
                    Task { await service.install() }
                }
                .buttonStyle(.kitPrimary)
                .disabled(busy)
            }
            if busy {
                Text(UpdateService.busyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func idleUpdateRow(service: UpdateService) -> some View {
        if service.updatesSupported {
            HStack {
                Text("No updates available")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates") {
                    Task { await service.checkForUpdates() }
                }
            }
        } else {
            Text("Updates for this build are distributed out of band")
                .foregroundStyle(.secondary)
        }
    }

}
