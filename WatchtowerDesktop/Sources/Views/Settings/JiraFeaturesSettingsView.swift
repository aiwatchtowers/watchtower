import SwiftUI

struct JiraFeaturesSettingsView: View {
    @State private var featuresState: JiraFeaturesState?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionError: String?

    var body: some View {
        Section("Jira Features") {
            if isLoading {
                ProgressView("Loading features...")
            } else if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") { loadFeatures() }
            } else if let state = featuresState {
                featuresContent(state)
            }

            if let err = actionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { loadFeatures() }
    }

    // MARK: - Content

    private func featuresContent(
        _ state: JiraFeaturesState
    ) -> some View {
        Group {
            headerBadge(state)
            featureGroup(
                title: "Your Work",
                features: [
                    ("my_issues_in_briefing", "My Issues in Briefing"),
                    ("awaiting_my_input", "Awaiting My Input"),
                    ("who_ping", "Who to Ping")
                ],
                state: state
            )
            featureGroup(
                title: "Team Visibility",
                features: [
                    ("team_workload", "Team Workload"),
                    ("blocker_map", "Blocker Map"),
                    ("iteration_progress", "Iteration Progress")
                ],
                state: state
            )
            featureGroup(
                title: "Product & Strategy",
                features: [
                    ("epic_progress", "Epic Progress"),
                    ("release_dashboard", "Release Dashboard"),
                    ("without_jira_detection", "Without Jira Detection")
                ],
                state: state
            )
            featureGroup(
                title: "Automation",
                features: [
                    ("track_jira_linking", "Track Jira Linking"),
                    ("write_back_suggestions", "Write-Back Suggestions")
                ],
                state: state
            )
            resetButton
        }
    }

    private func headerBadge(
        _ state: JiraFeaturesState
    ) -> some View {
        let enabled = state.features.values.filter { $0 }.count
        let total = state.features.count
        return HStack {
            Image(systemName: "person.badge.shield.checkmark")
                .foregroundStyle(.blue)
            Text("Preset: \(state.roleDisplay) (\(enabled) of \(total) features enabled)")
                .font(.callout)
        }
    }

    // MARK: - Feature Groups

    private func featureGroup(
        title: String,
        features: [(key: String, label: String)],
        state: JiraFeaturesState
    ) -> some View {
        GroupBox(title) {
            ForEach(features, id: \.key) { feature in
                featureToggle(
                    key: feature.key,
                    label: feature.label,
                    state: state
                )
            }
        }
    }

    private func featureToggle(
        key: String,
        label: String,
        state: JiraFeaturesState
    ) -> some View {
        let isOn = state.features[key] ?? false
        let isDefault = state.defaults[key] ?? false
        let differs = isOn != isDefault

        return Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                toggleFeature(key: key, enable: newValue)
            }
        )) {
            HStack(spacing: 4) {
                Text(label)
                if differs {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Differs from role default")
                }
            }
        }
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button("Reset to Role Defaults") {
            resetToDefaults()
        }
        .foregroundStyle(.red)
    }

    // MARK: - CLI Actions

    private func loadFeatures() {
        guard let cliPath = Constants.findCLIPath() else {
            loadError = "Watchtower CLI not found"
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["jira", "features", "--json"]
            process.environment = Constants.resolvedEnvironment()
            process.currentDirectoryURL =
                Constants.processWorkingDirectory()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadError = "Failed to launch CLI"
                }
                return
            }

            let stdoutData = stdoutPipe.fileHandleForReading
                .readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading
                .readDataToEndOfFile()
            process.waitUntilExit()

            await MainActor.run {
                isLoading = false
                if process.terminationStatus != 0 {
                    let stderr = String(
                        data: stderrData, encoding: .utf8
                    )?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""
                    loadError = stderr.isEmpty
                        ? "Failed to load features"
                        : String(stderr.prefix(200))
                    return
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let decoded = try? decoder.decode(
                    JiraFeaturesState.self, from: stdoutData
                ) {
                    featuresState = decoded
                } else {
                    loadError = "Failed to parse features JSON"
                }
            }
        }
    }

    private func toggleFeature(key: String, enable: Bool) {
        guard let cliPath = Constants.findCLIPath() else {
            actionError = "Watchtower CLI not found"
            return
        }

        actionError = nil
        // Optimistic update
        featuresState?.features[key] = enable

        let action = enable ? "enable" : "disable"

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [
                "jira", "features", action, key
            ]
            process.environment = Constants.resolvedEnvironment()
            process.currentDirectoryURL =
                Constants.processWorkingDirectory()

            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    actionError = "Failed to launch CLI"
                    // Revert optimistic update
                    featuresState?.features[key] = !enable
                }
                return
            }

            let stderrData = stderrPipe.fileHandleForReading
                .readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let stderr = String(
                    data: stderrData, encoding: .utf8
                )?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                await MainActor.run {
                    actionError = stderr.isEmpty
                        ? "Failed to \(action) feature"
                        : String(stderr.prefix(200))
                    featuresState?.features[key] = !enable
                }
            }
        }
    }

    private func resetToDefaults() {
        guard let cliPath = Constants.findCLIPath() else {
            actionError = "Watchtower CLI not found"
            return
        }

        actionError = nil

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["jira", "features", "reset"]
            process.environment = Constants.resolvedEnvironment()
            process.currentDirectoryURL =
                Constants.processWorkingDirectory()

            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    actionError = "Failed to launch CLI"
                }
                return
            }

            let stderrData = stderrPipe.fileHandleForReading
                .readDataToEndOfFile()
            process.waitUntilExit()

            await MainActor.run {
                if process.terminationStatus != 0 {
                    let stderr = String(
                        data: stderrData, encoding: .utf8
                    )?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""
                    actionError = stderr.isEmpty
                        ? "Reset failed"
                        : String(stderr.prefix(200))
                } else {
                    // Reload features after reset
                    loadFeatures()
                }
            }
        }
    }
}

// MARK: - Features State Model

struct JiraFeaturesState: Codable {
    let role: String
    let roleDisplay: String
    var features: [String: Bool]
    let defaults: [String: Bool]
}
