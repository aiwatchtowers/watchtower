import SwiftUI
import WatchtowerCore

/// System tab — workspace identity, AI provider, sync cadence, daemon
/// status, storage/data management, log viewer, and app updates.
struct SystemSettings: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Bindable var config: ConfigService
    @State private var connectionTestRunning = false
    @State private var connectionTestResult: String?
    @State private var connectionTestSuccess = false
    // Deliberately a separate instance from appState.daemonManager — a
    // fire-and-forget control handle used only by the updater's install step.
    @State private var daemonManager = DaemonManager()

    var body: some View {
        Form {
            Section("Workspace") {
                LabeledContent("Active Workspace") {
                    Text(config.activeWorkspace ?? "None")
                        .foregroundStyle(.secondary)
                }
            }
            aiSection
            syncSection
            DaemonSettings()
            DataSettings()
                .environment(appState)
            logsSection
            updateSection
            usageLinkSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
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
        Section(header: Text("AI")) {
            aiProviderPicker
            aiModelField
            aiWorkersField
            claudeCLIPathRow
            if config.aiProvider == "codex" {
                codexCLIPathRow
            }
            testConnectionRow
        }
    }

    private var aiProviderPicker: some View {
        Picker(
            "AI Provider",
            selection: Binding(
                get: { config.aiProvider ?? "claude" },
                set: { newProvider in
                    let oldProvider = config.aiProvider ?? "claude"
                    config.aiProvider = newProvider
                    // Reset model when switching providers so it doesn't carry over
                    if newProvider != oldProvider {
                        config.aiModel = nil
                        connectionTestResult = nil
                    }
                }
            )
        ) {
            Text("Claude").tag("claude")
            Text("Codex").tag("codex")
        }
    }

    private var aiModelField: some View {
        TextField(
            "Model",
            text: Binding(
                get: { config.aiModel ?? "" },
                set: { config.aiModel = $0.isEmpty ? nil : $0 }
            ),
            prompt: Text(config.aiProvider == "codex" ? "gpt-5.4" : "claude-sonnet-4-6")
        )
    }

    private var aiWorkersField: some View {
        TextField(
            "Workers",
            value: Binding(
                get: { config.aiWorkers },
                set: { config.aiWorkers = $0 }
            ),
            format: .number,
            prompt: Text("5")
        )
        .help("Max parallel LLM calls across all pipelines")
    }

    private var claudeCLIPathRow: some View {
        HStack {
            TextField(
                "Claude CLI Path",
                text: Binding(
                    get: { config.claudePath ?? "" },
                    set: { config.claudePath = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("auto-detect")
            )
            cliStatusIcon(foundPath: Constants.findInPath("claude"), notFoundHelp: "Claude CLI not found")
        }
        .help("Override auto-detection. Run 'which claude' in terminal to find the path.")
    }

    private var codexCLIPathRow: some View {
        HStack {
            TextField(
                "Codex CLI Path",
                text: Binding(
                    get: { config.codexPath ?? "" },
                    set: { config.codexPath = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("auto-detect")
            )
            cliStatusIcon(foundPath: Constants.findInPath("codex"), notFoundHelp: "Codex CLI not found")
        }
        .help("Override auto-detection. Run 'which codex' in terminal to find the path.")
    }

    @ViewBuilder
    private func cliStatusIcon(foundPath: String?, notFoundHelp: String) -> some View {
        if let foundPath {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Found: \(foundPath)")
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(notFoundHelp)
        }
    }

    private var testConnectionRow: some View {
        HStack {
            Button {
                testConnection()
            } label: {
                HStack(spacing: 4) {
                    if connectionTestRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(connectionTestRunning ? "Testing..." : "Test Connection")
                }
            }
            .disabled(connectionTestRunning)

            if let result = connectionTestResult {
                Image(systemName: connectionTestSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(connectionTestSuccess ? .green : .red)
                Text(result)
                    .font(.caption)
                    .foregroundStyle(connectionTestSuccess ? .green : .red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
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

            case .checking:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates...")
                        .foregroundStyle(.secondary)
                }

            case let .available(version, notes, _):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Version \(version) available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Spacer()
                        Button("Download") {
                            Task { await service.downloadUpdate() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }

            case .downloading(let progress):
                HStack {
                    ProgressView(value: progress)
                        .frame(maxWidth: 200)
                    Text("Downloading...")
                        .foregroundStyle(.secondary)
                }

            case .readyToInstall:
                HStack {
                    Label("Ready to install", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Install & Restart") {
                        Task { await service.install(daemonManager: daemonManager) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .installing:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing update...")
                        .foregroundStyle(.secondary)
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

    // MARK: - Helpers

    private func testConnection() {
        let isCodex = (config.aiProvider ?? "claude") == "codex"
        let cliPath: String? = isCodex ? Constants.findInPath("codex") : Constants.findInPath("claude")
        let providerName = isCodex ? "Codex" : "Claude"
        let defaultModel = isCodex ? "gpt-5.4" : "claude-sonnet-4-6"

        guard let path = cliPath else {
            connectionTestResult = "\(providerName) CLI not found"
            connectionTestSuccess = false
            return
        }

        connectionTestRunning = true
        connectionTestResult = nil

        let model = (config.aiModel ?? "").isEmpty ? defaultModel : (config.aiModel ?? defaultModel)

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)

            if isCodex {
                process.arguments = ["exec", "--model", model, "--json", "--skip-git-repo-check", "-c", "approval_policy=never", "respond with: OK"]
            } else {
                process.arguments = ["-p", "respond with: OK", "--output-format", "text", "--model", model]
            }

            process.environment = Constants.resolvedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    connectionTestRunning = false
                    connectionTestSuccess = false
                    connectionTestResult = "Failed to launch: \(error.localizedDescription)"
                }
                return
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            await MainActor.run {
                connectionTestRunning = false
                if process.terminationStatus == 0 && !stdout.isEmpty {
                    connectionTestSuccess = true
                    connectionTestResult = "Connected (\(model))"
                } else {
                    connectionTestSuccess = false
                    connectionTestResult = Self.diagnoseError(stderr: stderr, exitCode: process.terminationStatus)
                }
            }
        }
    }

    private static func diagnoseError(stderr: String, exitCode: Int32) -> String {
        let lower = stderr.lowercased()
        if lower.contains("not authenticated") || lower.contains("unauthorized")
            || lower.contains("api key") || lower.contains("log in") || lower.contains("login") {
            return "Not authenticated. Run 'claude' in Terminal."
        }
        if lower.contains("model") && (lower.contains("access") || lower.contains("available") || lower.contains("permission")) {
            return "Model not available for your account."
        }
        if lower.contains("rate limit") || lower.contains("overloaded") {
            return "API overloaded. Try again later."
        }
        if lower.contains("network") || lower.contains("connection") || lower.contains("timed out") {
            return "Network error."
        }
        if !stderr.isEmpty {
            let short = stderr.count > 200 ? String(stderr.prefix(200)) + "..." : stderr
            return "Error (exit \(exitCode)): \(short)"
        }
        return "Failed (exit code \(exitCode))"
    }
}
