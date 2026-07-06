import SwiftUI

struct MobileSettings: View {
    @Environment(AppState.self) private var appState
    @AppStorage(Constants.mobileSyncEnabledKey) private var mobileSyncEnabled = false

    var body: some View {
        Form {
            Section("Mobile Sync") {
                Toggle("Enable Mobile Sync", isOn: $mobileSyncEnabled)

                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
            }

            Section {
                Text("""
                    Syncs briefings, inbox, tasks, tracks, digests, calendar and people cards \
                    to the Watchtower iOS app through your private iCloud, and relays mobile \
                    actions and chat back to this Mac. Requires an iCloud account and a signed \
                    build with iCloud entitlements — unsigned development builds show "unavailable". \
                    While unavailable, iCloud is re-checked every 10 minutes and sync starts \
                    automatically once it returns.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: mobileSyncEnabled) { _, enabled in
            if enabled {
                appState.startMobileHub()
            } else {
                appState.stopMobileHub()
            }
        }
    }

    private var statusText: String {
        switch appState.mobileHubStatus {
        case .running: "Running"
        case .starting: "Starting…"
        case .unavailable(let reason): "Unavailable — \(reason)"
        case .off: mobileSyncEnabled ? "Not running" : "Off"
        }
    }

    private var statusColor: Color {
        switch appState.mobileHubStatus {
        case .running: .green
        case .unavailable: .orange
        case .starting, .off: .secondary
        }
    }
}
