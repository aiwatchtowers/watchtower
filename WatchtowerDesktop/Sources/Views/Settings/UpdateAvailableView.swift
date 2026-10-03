import SwiftUI
import WatchtowerCore

/// The "update available" window: shown once per version by a background
/// check (`UpdateService.presentUpdateWindow`), so an app living in the tray
/// does not hide a release behind a tray item nobody opens. Shows the
/// release notes and drives the same download → install → restart flow as
/// Settings → System; the state lives in `UpdateService`, so closing the
/// window mid-download loses nothing.
struct UpdateAvailableView: View {
    static let sceneID = "update-available"

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var service: UpdateService { appState.updateService }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            notes
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 320, maxHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.availableVersion.map { "Watchtower \($0) is available" } ?? "Watchtower is up to date")
                    .font(.headline)
                Text("You have \(Constants.appVersion).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's New")
                .font(.subheadline.weight(.semibold))
            if service.availableNotes.isEmpty {
                Text("No release notes for this version.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    MarkdownView(text: service.availableNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .environment(\.openURL, AllowedURLSchemes.openURLAction)
    }

    @ViewBuilder
    private var footer: some View {
        switch service.state {
        case .available:
            HStack {
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Update Now") {
                    Task { await downloadAndInstall() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }

        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Text("Downloading...")
                    .foregroundStyle(.secondary)
            }

        case .readyToInstall:
            readyToInstallRow

        case .installing:
            progressRow("Installing update...")

        case .restarting:
            progressRow("Restarting Watchtower...")

        case .restartRequired:
            HStack {
                Label("Update installed — restart Watchtower to finish", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Restart Now") {
                    Task { await service.relaunch() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Update error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                    Button("Retry") {
                        Task { await service.checkForUpdates() }
                    }
                }
            }

        case .idle, .checking:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Install & Restart, under the same busy gate as `UpdateService.install()`.
    private var readyToInstallRow: some View {
        let busy = appState.meetingRecorderCenter.isBusy
        return VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Label("Ready to install", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Later") { dismiss() }
                Button("Install & Restart") {
                    Task { await service.install() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
            if busy {
                Text(UpdateService.busyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progressRow(_ title: String) -> some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    /// One click for the whole update; a busy recorder stops it at "Ready to
    /// install", where the row says what to finish first.
    private func downloadAndInstall() async {
        await service.downloadUpdate()
        guard case .readyToInstall = service.state, !appState.meetingRecorderCenter.isBusy else { return }
        await service.install()
    }
}
