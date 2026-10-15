import Foundation

/// The names a workbench folder's Claude Code install answers to: the skill
/// the prompts the Desktop types name, and the MCP server it registers.
/// Go twins: `devpack.WorkbenchSkillName` and `WorkbenchMCPServerName`.
package enum WorkbenchNames {
    package static let skill = "watchtower-workbench"
    package static let mcpServer = "watchtower-workbench"
    /// The skill and MCP server name of a folder set up before the
    /// Workbench rename; `workbench delete` removes those too
    /// (Go `devpack.LegacySkillName`).
    package static let preRename = "watchtower-project"
}
