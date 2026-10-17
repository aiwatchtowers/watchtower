import SwiftUI
import WatchtowerCore

/// Sheet that imports the MCP servers of the owner's own codex
/// (~/.codex/config.toml) and Claude Code (~/.claude.json) configs as Quick
/// Connections (board #594): the codex chat no longer reads ~/.codex, so this
/// one click brings those servers back. Every importable server starts
/// ticked unless its config turned it off; one that cannot be imported shows
/// Go's reason instead of a checkbox. Import enables each picked server (its
/// tools are listed, QC-02) and runs the OAuth sign-in for an http server
/// that needs one; Close or Cancel stops a running sign-in.
struct ImportExternalConnectionsView: View {
    let vm: ExternalConnectionsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import MCP Servers")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { stop() }
                    .buttonStyle(.plain)
            }
            Text(
                "Servers from ~/.codex/config.toml and ~/.claude.json. Each one you pick becomes a "
                    + "Quick Connection: its keys move to a private file, and the assistant gets only its read-only tools."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            serverList

            if let err = vm.importError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if vm.isImporting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { stop() }
                Button("Import") {
                    Task {
                        let names = vm.importList?.servers.map(\.name).filter(picked.contains) ?? []
                        if await vm.importConnections(names) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || vm.isImporting || vm.isBusy)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            await vm.loadImportCandidates()
            picked = Set(vm.importList?.servers.filter(\.pickedByDefault).map(\.name) ?? [])
        }
    }

    /// Close or Cancel: a running import (its OAuth sign-in) stops first.
    private func stop() {
        if vm.isImporting { vm.cancelImport() }
        dismiss()
    }

    @ViewBuilder
    private var serverList: some View {
        if let list = vm.importList {
            ForEach(list.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if list.servers.isEmpty {
                Text("No MCP servers found in ~/.codex/config.toml or ~/.claude.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(list.servers) { server in
                            serverRow(server)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        } else if vm.importError == nil {
            ProgressView().controlSize(.small)
        }
    }

    private func serverRow(_ server: ExternalConnectionImportList.Server) -> some View {
        HStack(alignment: .top) {
            Toggle(isOn: Binding(
                get: { picked.contains(server.name) },
                set: { on in
                    if on { picked.insert(server.name) } else { picked.remove(server.name) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                    Text("\(server.kind) · from \(server.source == "codex" ? "~/.codex" : "~/.claude.json") · \(server.target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !server.enabled {
                        Text("Off in its config: imported turned off")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = server.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let skip = server.skip, !server.canImport {
                        Text("Can't import: \(skip)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!server.canImport || vm.isImporting)
        }
    }
}
