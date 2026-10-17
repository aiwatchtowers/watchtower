import Foundation

/// Quick Connections (external MCP servers) are wired for the claude and
/// codex providers (`ai.Client` and `codex.Client` both implement
/// `SetExternalMCPServers`); the ollama/runtime-B chat path never wires them.
/// This is the pure decision behind the Settings caption that tells the owner
/// when their active provider cannot use the connections they have enabled,
/// so "Enabled" is never a silent lie.
public enum QuickConnectionsProviderNotice {
    /// Nil when the provider is claude or codex (connections fully work);
    /// otherwise a caption telling the owner which providers they work with.
    /// An unrecognized or absent provider is treated as unsupported — the
    /// honest default; callers pass their own resolved default (the app
    /// treats an unset provider as claude before calling this).
    public static func caption(forProvider provider: String?) -> String? {
        guard provider == "claude" || provider == "codex" else {
            return "Quick Connections currently work only with the claude and codex AI providers. "
                + "Enabled connections are inert under the current provider."
        }
        return nil
    }

    /// The UserDefaults key of the one-time codex import notice.
    public static let codexImportNoticeDismissedKey = "quickConnections.codexImportNoticeDismissed"

    /// The one-time notice for codex chat users (board #594): their own
    /// codex MCP servers no longer load in the chat until imported. Nil for
    /// another provider, once dismissed (or after an import), or when their
    /// codex config declares no MCP server (`codex_servers`, nil = unknown).
    public static func codexImportNotice(forProvider provider: String?, dismissed: Bool, codexServers: Int?) -> String? {
        guard provider == "codex", !dismissed, (codexServers ?? 0) > 0 else { return nil }
        return "Your own codex MCP servers are no longer loaded in the Watchtower chat. "
            + "Import them to use them here, with read-only tools only."
    }
}
