import SwiftUI
import AppKit

/// Menu-bar tray content: status line + the only two actions the tray offers
/// (open the desktop window, quit Watchtower completely — daemon included).
struct TrayMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState
    @State private var daemonManager = DaemonManager()

    var body: some View {
        TrayMenuContent(isRunning: daemonManager.isRunning, cliStoreError: appState.cliStoreError) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onAppear { daemonManager.checkStatus() }
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
    let cliStoreError: String?
    let openAction: () -> Void

    static func statusText(isRunning: Bool) -> String {
        isRunning ? "Syncing in background" : "Sync daemon not running"
    }

    var body: some View {
        Group {
            Text(Self.statusText(isRunning: isRunning))
            if let cliStoreError {
                Text("CLI store: \(cliStoreError)")
            }
            Divider()
            Button("Open Watchtower", action: openAction)
            Divider()
            Button("Quit Watchtower") {
                NSApp.terminate(nil)
            }
        }
    }
}
