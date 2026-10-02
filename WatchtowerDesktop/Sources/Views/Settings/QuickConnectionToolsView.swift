import SwiftUI
import WatchtowerCore

/// One Quick Connection's tools (QC-02), under its row in Settings →
/// Connections: which tools the assistant may call. Read-only and unmarked
/// tools toggle; a tool the server declares a write has no toggle (owner
/// decision 2026-10-02 — external writes wait for an Approve step). Every
/// change goes through `watchtower connections tools`; the verdicts are Go's.
struct QuickConnectionToolsView: View {
    let connection: ExternalConnection
    let vm: ExternalConnectionsViewModel

    private var list: ExternalConnectionTools? { vm.toolLists[connection.id] }
    private var running: Bool { vm.toolsInFlight.contains(connection.id) }
    private var controlsDisabled: Bool { running || vm.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let list {
                if list.listed {
                    if list.tools.isEmpty {
                        caption("The server lists no tools.")
                    }
                    ForEach(list.tools) { tool in
                        toolRow(tool)
                    }
                } else if list.stale {
                    caption("The saved tool list is from before write tools were marked, so none is available "
                        + "to the assistant until it is listed again. Refresh the list to fetch it.")
                } else {
                    caption("Tools not listed yet, so none is available to the assistant. Refresh the list to fetch them.")
                }
            } else if vm.toolsErrors[connection.id] == nil {
                caption("Loading tools…")
            }
            if let err = vm.toolsErrors[connection.id] {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task(id: connection.id) {
            if list == nil { await vm.loadTools(connection) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let list, list.listed {
                Text(summary(list))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if running {
                ProgressView().controlSize(.small)
            }
            if list?.explicit == true {
                Button("Use defaults") {
                    Task { await vm.useDefaultTools(connection) }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(controlsDisabled)
                .help("Allow exactly the tools known to be read-only again")
            }
            Button("Refresh list") {
                Task { await vm.refreshTools(connection) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(controlsDisabled)
            .help("Fetch the tool list from the server again")
        }
    }

    private func toolRow(_ tool: ExternalConnectionTools.Tool) -> some View {
        HStack(spacing: 8) {
            Text(tool.name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(kindLabel(tool.kind))
                .font(.caption2)
                .foregroundStyle(tool.kind == .write ? Color.orange : Color.secondary)
            Spacer()
            Toggle("Allowed", isOn: Binding(
                get: { tool.allowed },
                set: { newValue in
                    Task { await vm.setTool(tool.name, allowed: newValue, on: connection) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!tool.canToggle || controlsDisabled)
        }
        .help(kindHelp(tool.kind))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func summary(_ list: ExternalConnectionTools) -> String {
        let allowed = list.tools.filter(\.allowed).count
        let mode = list.explicit ? "your list" : "read-only tools"
        var text = "\(allowed) of \(list.tools.count) tools available (\(mode))"
        if let listed = Self.listedDate(list.listedAt) {
            text += " · listed \(listed.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }

    private func kindLabel(_ kind: ExternalConnectionTools.Tool.Kind) -> String {
        switch kind {
        case .readOnly: "read-only"
        case .unmarked: "unmarked"
        case .write: "write"
        }
    }

    private func kindHelp(_ kind: ExternalConnectionTools.Tool.Kind) -> String {
        switch kind {
        case .readOnly:
            "Known read-only: the server marks it so, or its name says it only reads."
        case .unmarked:
            "The server doesn't say whether this tool changes anything. Allow it only if you know it only reads."
        case .write:
            "The server marks this tool as a write. Write tools never reach the assistant until they get an Approve step."
        }
    }

    private static func listedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
