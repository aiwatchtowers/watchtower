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

    /// The refusal of a stored kind `raw` that is no agent kind of this
    /// version, word for word Go's `agentkind.Unsupported` (the phone reads
    /// either hub's): `agent kind "x" is not supported by this version
    /// (claude or codex)`.
    package static func unsupportedRefusal(_ raw: String) -> String {
        let names = allCases.map(\.rawValue)
        let choices = names.count <= 1 ? names.joined()
            : names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
        return "agent kind \"\(raw)\" is not supported by this version (\(choices))"
    }

    /// Every agent kind as an SQL list, `('claude','codex')`, so no query
    /// spells the list by hand.
    package static let sqlKinds = "(" + allCases.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")"
}
