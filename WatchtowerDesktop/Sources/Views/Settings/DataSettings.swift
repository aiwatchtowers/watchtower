import SwiftUI
import WatchtowerCore

struct DataSettings: View {
    @Environment(AppState.self) private var appState
    @State private var showResetConfirmation = false
    @State private var showFinalConfirmation = false
    @State private var isResetting = false
    @State private var resetError: String?
    @State private var configSize: String?
    @State private var databaseSize: String?
    @State private var cacheSize: String?
    @State private var sizesLoaded = false
    @State private var showLLMResetConfirmation = false
    @State private var isResettingLLM = false
    @State private var llmResetError: String?
    @State private var llmResetSuccess = false

    private let configDir = NSString("~/.config/watchtower").expandingTildeInPath
    private let dataDir = Constants.databasePath
    private let cacheDir = NSString("~/Library/Caches/WatchtowerDesktop").expandingTildeInPath

    var body: some View {
        Group {
            storageSection
            regenerateSection
            dangerZoneSection
        }
        .task { await refreshSizes() }
        .alert("Reset All Data?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                showFinalConfirmation = true
            }
        } message: {
            Text("This will permanently delete all Watchtower data "
                + "including config, database, and caches. "
                + "The app will quit afterwards. This cannot be undone.")
        }
        .alert("Reset AI Data?", isPresented: $showLLMResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset & Regenerate", role: .destructive) {
                Task { await performLLMReset() }
            }
        } message: {
            Text("All AI-generated data (digests, tracks, people "
                + "analytics, guides, feedback) will be deleted. "
                + "The daemon will be stopped and all generation pipelines "
                + "will re-run. Slack data and your profile are preserved.")
        }
        .alert("Are you sure?", isPresented: $showFinalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Everything", role: .destructive) {
                Task { await performReset() }
            }
        } message: {
            Text("Last chance. All data will be permanently deleted and the app will quit.")
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Config") {
                HStack {
                    Text(configDir)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    sizeLabel(configSize)
                }
            }

            LabeledContent("Database") {
                HStack {
                    Text(dataDir)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    sizeLabel(databaseSize)
                }
            }

            LabeledContent("Caches") {
                HStack {
                    Text(cacheDir)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    sizeLabel(cacheSize)
                }
            }
        }
    }

    private var regenerateSection: some View {
        Section("Regenerate AI Data") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reset AI-Generated Data")
                    .font(.headline)
                Text("Deletes all digests, tracks, people analytics, "
                    + "communication guides, and feedback. "
                    + "Stops the daemon, then re-runs all generation "
                    + "pipelines from scratch. Raw Slack data, config, "
                    + "and your profile are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(role: .destructive) {
                        showLLMResetConfirmation = true
                    } label: {
                        if isResettingLLM {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Resetting…")
                            }
                        } else {
                            Text("Reset & Regenerate…")
                        }
                    }
                    .disabled(isResettingLLM)

                    if llmResetSuccess {
                        Label("Pipelines started", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    if let error = llmResetError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }

            }
            .padding(.vertical, 4)
        }
    }

    private var dangerZoneSection: some View {
        Section("Danger Zone") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reset All Data")
                    .font(.headline)
                Text("Stops the daemon, removes config, database, "
                    + "caches, and macOS preferences. "
                    + "The app will quit after reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    if isResetting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Reset All Data…")
                    }
                }
                .disabled(isResetting)
                if let resetError {
                    Text(resetError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A size, or a placeholder while the walk is still running.
    @ViewBuilder
    private func sizeLabel(_ size: String?) -> some View {
        if let size {
            Text(size)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if !sizesLoaded {
            Text("…")
                .foregroundStyle(.secondary)
        }
    }

    /// Walks the three directories off the main actor: the data directory
    /// holds the memory vault's loose git objects (tens of thousands of
    /// files), and a main-thread walk froze the System tab on open.
    private func refreshSizes() async {
        let dirs = (configDir, dataDir, cacheDir)
        let sizes = await Task.detached(priority: .utility) {
            (Self.directorySize(dirs.0), Self.directorySize(dirs.1), Self.directorySize(dirs.2))
        }.value
        guard !Task.isCancelled else { return }
        (configSize, databaseSize, cacheSize) = sizes
        sizesLoaded = true
    }

    private func performLLMReset() async {
        isResettingLLM = true
        llmResetError = nil
        llmResetSuccess = false

        do {
            try await appState.resetLLMData()
            llmResetSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                llmResetSuccess = false
            }
        } catch {
            llmResetError = error.localizedDescription
        }

        isResettingLLM = false
    }

    private func performReset() async {
        isResetting = true
        resetError = nil
        let configDir = configDir
        let dataDir = dataDir
        // One item on the app's start queue: stop the daemon, and delete
        // only once it is really gone — no start lands in between.
        let stopped = await appState.enqueueDaemonStart { () -> Bool in
            let daemon = DaemonManager()
            daemon.resolvePathIfNeeded()
            if DaemonManager.checkDaemonRunning() {
                await daemon.stopDaemon()
            }
            do {
                try await DaemonManager.waitForDaemonExit()
            } catch {
                return false
            }
            Self.removeEverything(configDir: configDir, dataDir: dataDir)
            return true
        }.value
        guard stopped else {
            resetError = "The background sync did not stop, so nothing was deleted. Try again."
            isResetting = false
            return
        }

        // L5 fix: dispatch terminate to main thread explicitly (not from async context).
        // A stop-only quit: sessions kept in the session host would belong to
        // the wiped workspace and could never be reattached (board #496).
        await MainActor.run {
            TrayAppDelegate.requestQuit(stoppingSessions: true)
        }
    }

    /// Config, database, preferences, caches and crash reports.
    @MainActor
    private static func removeEverything(configDir: String, dataDir: String) {
        // 2. Remove config & database
        let fm = FileManager.default
        try? fm.removeItem(atPath: configDir)
        try? fm.removeItem(atPath: dataDir)

        // 3. Remove macOS preferences & caches
        let home = NSHomeDirectory()
        let pathsToRemove = [
            "\(home)/Library/Preferences/com.watchtower.desktop.plist",
            "\(home)/Library/Preferences/WatchtowerDesktop.plist",
            "\(home)/Library/Caches/WatchtowerDesktop",
            "\(home)/Library/HTTPStorages/WatchtowerDesktop"
        ]
        for path in pathsToRemove {
            try? fm.removeItem(atPath: path)
        }

        // Remove crash reports / diagnostic logs matching pattern
        let crashDirs: [(String, String)] = [
            ("\(home)/Library/Application Support/CrashReporter", "WatchtowerDesktop_"),
            ("\(home)/Library/Logs/DiagnosticReports", "WatchtowerDesktop-")
        ]
        for (dir, prefix) in crashDirs {
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for file in files where file.hasPrefix(prefix) {
                    try? fm.removeItem(atPath: "\(dir)/\(file)")
                }
            }
        }

        // Remove UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.removePersistentDomain(forName: "com.watchtower.desktop")
        UserDefaults.standard.removePersistentDomain(forName: "WatchtowerDesktop")
    }

    nonisolated private static func directorySize(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys
        ) else { return nil }

        var totalSize: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            totalSize += Int64(size)
        }

        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}
