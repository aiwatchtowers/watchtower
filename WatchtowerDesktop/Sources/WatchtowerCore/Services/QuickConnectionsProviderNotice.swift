import Foundation

/// Quick Connections (external MCP servers) are wired only for the claude
/// provider in v1 — codex never receives them (`codex.Client` has no
/// `SetExternalMCPServers`) and the ollama/runtime-B chat path never wires
/// them at all. This is the pure decision behind the Settings caption that
/// tells the owner when their active provider cannot use the connections
/// they have enabled, so "Enabled" is never a silent lie.
public enum QuickConnectionsProviderNotice {
    /// Nil when the provider is claude (connections fully work); otherwise a
    /// caption telling the owner Quick Connections are claude-only today.
    /// An unrecognized or absent provider is treated as non-claude — the
    /// honest default; callers pass their own resolved default (the app
    /// treats an unset provider as claude before calling this).
    public static func caption(forProvider provider: String?) -> String? {
        guard provider == "claude" else {
            return "Quick Connections currently work only with the claude AI provider. "
                + "Enabled connections are inert under the current provider."
        }
        return nil
    }
}
