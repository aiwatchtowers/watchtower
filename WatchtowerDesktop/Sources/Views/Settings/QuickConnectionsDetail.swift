import SwiftUI
import WatchtowerCore

/// Quick Connections detail pane in the Connections tab — the owner-managed
/// list of external MCP servers (`external_connections` table, migration
/// 00064) whose read-only tools can be surfaced in the assistant chat. A
/// connection is created disabled; the owner enables it explicitly (per-
/// connection consent). Structural copy of `SlackConnectionDetail`'s
/// `slackAccountsSection`.
struct QuickConnectionsDetail: View {
    @Environment(AppState.self) private var appState
    @State private var showAddConnectionSheet = false
    @State private var connectionPendingRemoval: ExternalConnection?

    var body: some View {
        Form {
            quickConnectionsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var quickConnectionsSection: some View {
        Section("Quick Connections") {
            if let vm = appState.externalConnectionsViewModel {
                if vm.connections.isEmpty {
                    Text("No external connections configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.connections) { connection in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.name)
                                Text(connection.kind)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(connectionStatusColor(connection))
                                .frame(width: 8, height: 8)
                                .help(connection.isOK
                                    ? "OK"
                                    : (connection.error.isEmpty ? connection.status : connection.error))
                            Toggle("Enabled", isOn: Binding(
                                get: { connection.enabled },
                                set: { newValue in
                                    Task { await vm.setEnabled(connection, enabled: newValue) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(vm.isBusy)
                            Button("Remove") {
                                connectionPendingRemoval = connection
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(vm.isBusy)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Connection") {
                    showAddConnectionSheet = true
                }
                .disabled(vm.isBusy)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddConnectionSheet) {
            AddExternalConnectionView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(connectionPendingRemoval?.name ?? "this connection")?",
            isPresented: Binding(
                get: { connectionPendingRemoval != nil },
                set: { if !$0 { connectionPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Connection", role: .destructive) {
                if let connection = connectionPendingRemoval {
                    Task { await appState.externalConnectionsViewModel?.remove(connection) }
                }
                connectionPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the connection and its stored secret. The assistant loses access to its tools immediately.")
        }
    }

    private func connectionStatusColor(_ connection: ExternalConnection) -> Color {
        connection.isOK ? .green : .red
    }
}
