import Foundation

/// The coding agent a workbench terminal session runs (board #399): the
/// `terminal_sessions.kind` values that are not a plain shell. Mirrors Go's
/// `internal/agentkind`.
package enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex

    /// The agent's product name, as the UI shows it.
    package var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Every agent kind as an SQL list, `('claude','codex')`, so no query
    /// spells the list by hand.
    package static let sqlKinds = "(" + allCases.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")"
}
