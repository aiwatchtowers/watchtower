import Foundation

/// The names a workbench folder's Claude Code install answers to. A folder
/// set up before the Workbench rename (spec 2026-10-02 §5.3) has only the old
/// skill and MCP server until the owner runs Re-run Setup, so the prompts the
/// Desktop types and the delete confirmation name what that folder has.
/// Go twins: `devpack.WorkbenchSkillName` / `LegacySkillName` and
/// `WorkbenchMCPServerName` / `LegacyMCPServerName`.
package enum WorkbenchVocabulary: Equatable, Sendable {
    case current
    case legacy

    package var skillName: String {
        switch self {
        case .current: "watchtower-workbench"
        case .legacy: "watchtower-project"
        }
    }

    package var mcpServerName: String {
        switch self {
        case .current: "watchtower-workbench"
        case .legacy: "watchtower-project"
        }
    }
}
