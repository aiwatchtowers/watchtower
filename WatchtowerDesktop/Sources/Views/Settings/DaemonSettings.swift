import SwiftUI

struct DaemonSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Reads the app-wide DaemonManager, so a start/stop failure raised on
        // the launch path is visible here and in the tray alike.
        DaemonSettingsContent(
            isRunning: appState.daemonManager.isRunning,
            binaryPath: appState.daemonManager.watchtowerPath,
            errorMessage: appState.daemonManager.errorMessage
        )
        .onAppear {
            appState.daemonManager.resolvePathIfNeeded()
            appState.daemonManager.checkStatus()
        }
    }
}

/// Environment-free rendering half (the `TrayMenuContent` split, for the same
/// ViewInspector reason).
struct DaemonSettingsContent: View {
    let isRunning: Bool
    let binaryPath: String?
    let errorMessage: String?

    var body: some View {
        Form {
            Section("Daemon Status") {
                HStack {
                    Circle()
                        .fill(isRunning ? .green : .gray)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(isRunning ? "Running" : "Stopped")
                    Text(isRunning ? "Running" : "Stopped")
                }

                if let binaryPath {
                    LabeledContent("Binary", value: binaryPath)
                } else {
                    Text("watchtower binary not found")
                        .foregroundStyle(.red)
                }
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
