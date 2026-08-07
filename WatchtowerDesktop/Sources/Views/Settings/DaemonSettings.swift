import SwiftUI

struct DaemonSettings: View {
    @State private var daemonManager = DaemonManager()

    var body: some View {
        Form {
            Section("Daemon Status") {
                HStack {
                    Circle()
                        .fill(daemonManager.isRunning ? .green : .gray)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(daemonManager.isRunning ? "Running" : "Stopped")
                    Text(daemonManager.isRunning ? "Running" : "Stopped")
                }

                if let path = daemonManager.watchtowerPath {
                    LabeledContent("Binary", value: path)
                } else {
                    Text("watchtower binary not found")
                        .foregroundStyle(.red)
                }
            }

            if let error = daemonManager.errorMessage {
                Section("Error") {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            daemonManager.resolvePathIfNeeded()
            daemonManager.checkStatus()
        }
    }
}
