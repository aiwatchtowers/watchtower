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
    /// The provider the chat actually runs on — read from config.yaml (the
    /// value Go and the chat launcher use), never the Settings editor's
    /// unsaved in-memory pick, so an unsaved switch cannot silence the
    /// caption while the chat is still on another provider.
    @State private var providerID = "claude"
    @State private var showAddConnectionSheet = false
    @State private var connectionPendingRemoval: ExternalConnection?
    /// Connections whose Tools list is open.
    @State private var expandedTools: Set<Int> = []

    var body: some View {
        Form {
            quickConnectionsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .onAppear { providerID = Constants.aiProviderID() }
    }

    private var quickConnectionsSection: some View {
        Section("Quick Connections") {
            if let notice = QuickConnectionsProviderNotice.caption(forProvider: providerID) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // QC-02: by default the chat gets a connection's read-only tools
            // only; each connection's Tools list below changes that per tool.
            Text(
                "By default the assistant can use only the tools a server marks read-only "
                    + "(or, when it doesn't say, tools named get…, list…, search… and the like). "
                    + "Open a connection's Tools to change that; tools the server marks as writes stay off."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if let vm = appState.externalConnectionsViewModel {
                if vm.connections.isEmpty {
                    Text("No external connections configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.connections) { connection in
                        connectionRow(connection, vm: vm)
                        DisclosureGroup(isExpanded: toolsExpanded(connection)) {
                            QuickConnectionToolsView(connection: connection, vm: vm)
                        } label: {
                            Text("Tools").font(.caption)
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

    private func connectionRow(_ connection: ExternalConnection, vm: ExternalConnectionsViewModel) -> some View {
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
            if connection.needsSignIn {
                Button("Sign in again") {
                    Task { await vm.signIn(connection) }
                }
                .buttonStyle(.plain)
                .disabled(vm.isBusy)
            }
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

    private func toolsExpanded(_ connection: ExternalConnection) -> Binding<Bool> {
        Binding(
            get: { expandedTools.contains(connection.id) },
            set: { open in
                if open { expandedTools.insert(connection.id) } else { expandedTools.remove(connection.id) }
            }
        )
    }

    private func connectionStatusColor(_ connection: ExternalConnection) -> Color {
        if connection.isOK { return .green }
        // Red only when a new sign-in is the fix; a transient or tool-list
        // error is orange (its tooltip says what to do).
        return connection.needsSignIn ? .red : .orange
    }
}
