import SwiftUI
import WatchtowerCore
import ChatUI

/// The "update available" window: shown once per version by a background
/// check (`UpdateService.presentUpdateWindow`), so an app living in the tray
/// does not hide a release behind a tray item nobody opens. Shows the
/// release notes and drives the same download → install → restart flow as
/// Settings → System; the state lives in `UpdateService`, so closing the
/// window mid-download loses nothing. After an update, the first launch of
/// the new version opens it once on that version's notes
/// (`UpdateService.installedRelease`) when no newer update is on offer.
///
/// A required update (`UpdateService.requiredMinVersion`) opens it on every
/// background check and at launch, says why in one sentence, and offers no
/// way to put it off: no Later, no Close, the window's close button is
/// disabled — Quit Watchtower stays. Strings: `UpdateWindowCopy`.
struct UpdateAvailableView: View {
    static let sceneID = "update-available"

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private typealias Copy = UpdateWindowCopy

    private var service: UpdateService { appState.updateService }

    /// The just-installed release, unless a newer update is on offer.
    private var installed: UpdateService.InstalledRelease? {
        service.availableVersion == nil ? service.installedRelease : nil
    }

    private var required: Bool { service.isUpdateRequired }

    private var releaseNotes: String { installed?.notes ?? service.availableNotes }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            header
            if let minimum = service.requiredMinVersion {
                requiredNotice(minimum: minimum)
            }
            notes
            footer
        }
        .padding(Spacing.page)
        .frame(width: 520)
        .frame(minHeight: 320, maxHeight: 560)
        .controlSize(.small)
        .background(WindowCloseLock(locked: required))
        .onDisappear { service.dismissInstalledRelease() }
    }

    private var header: some View {
        HStack(spacing: Spacing.medium) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(Copy.title(offered: service.availableVersion, installed: installed?.version, required: required))
                    .font(.headline)
                Text(Copy.subtitle(running: service.runningVersion, showingInstalled: installed != nil))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requiredNotice(minimum: String) -> some View {
        Label {
            Text(Copy.requiredReason(minimum: minimum))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .card()
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Copy.notesHeader)
                .font(.subheadline.weight(.semibold))
            if releaseNotes.isEmpty {
                Text(Copy.noNotes)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    MarkdownView(text: releaseNotes)
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
                putOffButton(Copy.later)
                Button(Copy.updateNow) {
                    Task { await downloadAndInstall() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.kitPrimary)
            }

        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Text(Copy.downloading)
                    .foregroundStyle(.secondary)
            }

        case .readyToInstall:
            readyToInstallRow

        case .installing:
            progressRow(Copy.installing)

        case .restarting:
            progressRow(Copy.restarting)

        case .restartRequired:
            HStack {
                Label(Copy.restartRequired, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success)
                Spacer()
                Button(Copy.restartNow) {
                    Task { await service.relaunch() }
                }
                .buttonStyle(.kitPrimary)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Label(Copy.errorTitle, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.error)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    putOffButton(Copy.close)
                    Button(Copy.retry) {
                        Task { await service.checkForUpdates() }
                    }
                    .buttonStyle(.kitSecondary)
                }
            }

        case .idle, .checking:
            HStack {
                Spacer()
                if required {
                    putOffButton(Copy.close)
                    Button(Copy.checkAgain) {
                        Task { await service.checkForUpdates() }
                    }
                    .buttonStyle(.kitSecondary)
                    .disabled(service.state == .checking)
                } else {
                    Button(Copy.close) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.kitSecondary)
                }
            }
        }
    }

    /// The way out of the window: `title` (Later, Close) for an optional
    /// update; Quit Watchtower for a required one, which cannot be put off.
    @ViewBuilder
    private func putOffButton(_ title: String) -> some View {
        if required {
            Button(Copy.quit) { TrayAppDelegate.requestQuit() }
                .buttonStyle(.kitQuiet)
        } else {
            Button(title) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.kitSecondary)
        }
    }

    /// Install & Restart, under the same busy gate as `UpdateService.install()`.
    private var readyToInstallRow: some View {
        let busy = appState.meetingRecorderCenter.isBusy
        return VStack(alignment: .trailing, spacing: Spacing.small) {
            HStack {
                Label(Copy.readyToInstall, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success)
                Spacer()
                putOffButton(Copy.later)
                Button(Copy.installAndRestart) {
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

/// Disables the hosting window's close button (and so ⌘W, which beeps on a
/// window whose close button is disabled) while `locked`.
private struct WindowCloseLock: NSViewRepresentable {
    let locked: Bool

    func makeNSView(context: Context) -> LockView { LockView() }

    func updateNSView(_ nsView: LockView, context: Context) {
        nsView.locked = locked
    }

    final class LockView: NSView {
        var locked = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.standardWindowButton(.closeButton)?.isEnabled = !locked
        }
    }
}
