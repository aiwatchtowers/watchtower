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
            modelField(
                "Light Model",
                value: $config.aiModelLight,
                resolved: catalogProvider?.resolvedLight,
                help: "Cheap/fast tier: triage, rollups, dictation cleanup"
            )
            modelField(
                "Strong Model",
                value: $config.aiModelStrong,
                resolved: catalogProvider?.resolvedStrong,
                help: "Quality tier: situation cards, briefings, chat"
            )
            if selectedProviderID == "ollama" {
                ollamaURLRow
            }
            if let catalogError = appState.aiModelCatalog.lastError {
                Label("Model list unavailable: \(catalogError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            aiWorkersField
            claudeCLIPathRow
            if selectedProviderID == "codex" {
                codexCLIPathRow
            }
            testConnectionRow
        }
        .task { await appState.aiModelCatalog.load() }
    }

    /// One Swift copy of the default server URL (mirrors config.DefaultOllamaURL
    /// on the Go side — the placeholder and the test fallback share it).
    private static let defaultOllamaURL = "http://localhost:11434"

    private var selectedProviderID: String {
        config.aiProvider ?? "claude"
    }

    private var catalogProvider: AIModelCatalog.Provider? {
        appState.aiModelCatalog.provider(selectedProviderID)
    }

    /// Free-text model field with a suggestions menu fed by
    /// `watchtower ai models --json`. Empty = the provider default (an alias
    /// for Claude, so new model releases arrive without an app release).
    private func modelField(
        _ title: String,
        value: Binding<String?>,
        resolved: String?,
        help: String
    ) -> some View {
        HStack {
            TextField(
                title,
                text: Binding(
                    get: { value.wrappedValue ?? "" },
                    set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text({
                    if let resolved, !resolved.isEmpty { return resolved }
                    return selectedProviderID == "ollama" ? "choose a model" : "provider default"
                }())
            )
            .help(help)
            let suggestions = appState.aiModelCatalog.suggestions(for: selectedProviderID)
            if !suggestions.isEmpty {
                Menu {
                    Button("Default") { value.wrappedValue = nil }
                    Divider()
                    ForEach(suggestions, id: \.self) { model in
                        Button(model) { value.wrappedValue = model }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var ollamaURLRow: some View {
        HStack {
            TextField(
                "Server URL",
                text: Binding(
                    get: { config.aiOllamaURL ?? "" },
                    set: { config.aiOllamaURL = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text(Self.defaultOllamaURL)
            )
            .help("Any OpenAI-compatible server: Ollama, LM Studio, vLLM, ...")
            if let error = appState.aiModelCatalog.provider("ollama")?.error, !error.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
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
                    // Reset models when switching providers so they don't carry over
                    if newProvider != oldProvider {
                        config.aiModel = nil
                        config.aiModelLight = nil
                        config.aiModelStrong = nil
                        connectionTestResult = nil
                    }
                }
            )
        ) {
            Text("Claude").tag("claude")
            Text("Codex").tag("codex")
            Text("Ollama / Local").tag("ollama")
        }
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
                idleUpdateRow(service: service)

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

    // MARK: - Helpers

    /// The strong-tier model the test should exercise: the form value, else
    /// the catalog's resolved value, else the legacy ai.model field. The
    /// retired seeded literal is filtered like Go's ResolveModelsFor does —
    /// it means "never chose", and the pipelines will not use it.
    private var testModel: String {
        if let strong = config.aiModelStrong, !strong.isEmpty { return strong }
        if let resolved = catalogProvider?.resolvedStrong, !resolved.isEmpty { return resolved }
        let legacy = config.aiModel ?? ""
        return legacy == "claude-sonnet-4-6" ? "" : legacy
    }

    /// The light-tier model the test should exercise: the form value, else
    /// the catalog's resolved value. No legacy fallback — ai.model only ever
    /// configured the strong tier.
    private var testModelLight: String? {
        if let light = config.aiModelLight, !light.isEmpty { return light }
        return catalogProvider?.resolvedLight
    }

    private func testConnection() {
        if selectedProviderID == "ollama" {
            testOllamaConnection()
            return
        }
        let isCodex = selectedProviderID == "codex"
        let cliPath: String? = isCodex ? Constants.findInPath("codex") : Constants.findInPath("claude")
        let providerName = isCodex ? "Codex" : "Claude"

        guard let path = cliPath else {
            connectionTestResult = "\(providerName) CLI not found"
            connectionTestSuccess = false
            return
        }

        // Both tiers get probed — a broken light model would otherwise pass
        // the test and then fail every triage/digest call.
        let models = ConnectionTest.models(light: testModelLight, strong: testModel)
        guard !models.isEmpty else {
            // No form value and the catalog has not loaded: without a model
            // there is nothing meaningful to test (and hardcoding one here
            // would violate the no-model-names-in-Swift rule).
            connectionTestSuccess = false
            connectionTestResult = "Model list unavailable — enter a model first"
            return
        }

        connectionTestRunning = true
        connectionTestResult = nil

        Task.detached {
            var results: [(model: String, error: String?)] = []
            for model in models {
                results.append((model, Self.runCLIProbe(path: path, isCodex: isCodex, model: model)))
            }
            let (ok, message) = ConnectionTest.summary(results)
            await MainActor.run {
                connectionTestRunning = false
                connectionTestSuccess = ok
                connectionTestResult = message
            }
        }
    }

    /// One blocking CLI probe; nil means the model answered. nonisolated so the
    /// detached test task can run it off the main actor (View infers @MainActor).
    nonisolated private static func runCLIProbe(path: String, isCodex: Bool, model: String) -> String? {
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
            return "Failed to launch: \(error.localizedDescription)"
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 && !stdout.isEmpty {
            return nil
        }
        return diagnoseError(stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Test an OpenAI-compatible server with a direct chat-completions call,
    /// so the button exercises the exact URL and model in the form (saved or
    /// not) rather than whatever config is on disk.
    private func testOllamaConnection() {
        let base = (config.aiOllamaURL ?? "").isEmpty ? Self.defaultOllamaURL : (config.aiOllamaURL ?? "")
        let models = ConnectionTest.models(light: testModelLight, strong: testModel)
        guard !models.isEmpty else {
            connectionTestSuccess = false
            connectionTestResult = "Pick a model first (Strong Model field)"
            return
        }
        let endpoint = base.hasSuffix("/") ? base + "v1/chat/completions" : base + "/v1/chat/completions"
        guard let url = URL(string: endpoint) else {
            connectionTestSuccess = false
            connectionTestResult = "Invalid server URL"
            return
        }

        connectionTestRunning = true
        connectionTestResult = nil

        Task {
            var results: [(model: String, error: String?)] = []
            for model in models {
                results.append((model, await Self.probeOllama(url: url, model: model)))
            }
            let (ok, message) = ConnectionTest.summary(results)
            connectionTestSuccess = ok
            connectionTestResult = message
            connectionTestRunning = false
        }
    }

    /// One chat-completions probe against an OpenAI-compatible server; nil
    /// means the model answered.
    private static func probeOllama(url: URL, model: String) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "respond with: OK"]],
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return nil
            }
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            return "HTTP \(status): \(text)"
        } catch {
            return "Server unreachable: \(error.localizedDescription)"
        }
    }

    nonisolated private static func diagnoseError(stderr: String, exitCode: Int32) -> String {
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
