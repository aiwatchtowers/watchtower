import SwiftUI
import AppKit

/// Menu-bar tray content: status line + the only actions the tray offers
/// (open the desktop window, open Settings, quit Watchtower completely —
/// daemon included).
struct TrayMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppState.self) private var appState

    var body: some View {
        TrayMenuContent(
            isRunning: appState.daemonManager.isRunning,
            daemonError: appState.daemonManager.errorMessage,
            cliStoreError: appState.cliStoreError,
            quickCaptureAction: {
                // Same "become regular" move as Open Watchtower: the Quick
                // Capture window is a real window and needs a Dock icon /
                // activation to actually come to the front.
                ActivationPolicyDecision.becomeRegularAndActivate()
                appState.openQuickCapture?()
            },
            openAction: {
                // Opening from the tray is a deliberate "become regular" move —
                // it must win over a still-armed login-launch close observer
                // (see `TrayAppDelegate.endLoginLaunchClosing`), or a window
                // opened right after a login launch gets closed out from under
                // the user.
                (NSApp.delegate as? TrayAppDelegate)?.endLoginLaunchClosing()
                ActivationPolicyDecision.becomeRegularAndActivate()
                openWindow(id: TrayAppDelegate.mainWindowSceneID)
            },
            settingsAction: {
                // The policy watcher recomputes only on window CLOSE, so an
                // accessory-mode app must become regular here or Settings
                // opens with no menu bar. The login-launch close grace is NOT
                // ended: it targets the main window, which the user did not
                // ask for.
                ActivationPolicyDecision.becomeRegularAndActivate()
                openSettings()
            }
        )
        // The shared DaemonManager polls from AppState.initialize(); this only
        // refreshes the line the moment the menu is opened.
        .onAppear { appState.daemonManager.checkStatus() }
    }
}

/// The tray's actual rendering, split out from `TrayMenuView` so it takes no
/// `@Environment(AppState.self)` — ViewInspector (0.10.3, this repo) cannot
/// resolve that without a real render pass and crashes uncatchably when it
/// tries. Same shape as `RecordingIndicatorView`/`RecordingJobPill`: the
/// environment-wired view stays thin, the content it renders is a plain,
/// testable view.
struct TrayMenuContent: View {
    let isRunning: Bool
    let daemonError: String?
    let cliStoreError: String?
    let quickCaptureAction: () -> Void
    let openAction: () -> Void
    let settingsAction: () -> Void

    static func statusText(isRunning: Bool) -> String {
        isRunning ? "Syncing in background" : "Sync daemon not running"
    }

    var body: some View {
        Group {
            Text(Self.statusText(isRunning: isRunning))
            if let daemonError {
                Text("Daemon: \(daemonError)")
            }
            if let cliStoreError {
                Text("CLI store: \(cliStoreError)")
            }
            Divider()
            Button("New Voice Idea", action: quickCaptureAction)
            Divider()
            Button("Open Watchtower", action: openAction)
            Button("Settings…", action: settingsAction)
            Divider()
            Button("Quit Watchtower") {
                // Not NSApp.terminate directly: a presented sheet anywhere
                // makes SwiftUI veto termination before the delegate runs
                // (see TrayAppDelegate.requestQuit).
                TrayAppDelegate.requestQuit()
            }
        }
    }
}
