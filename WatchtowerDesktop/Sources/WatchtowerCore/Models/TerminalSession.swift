import Foundation
import GRDB

/// One `terminal_sessions` row (goose migration 00084): a named, resumable
/// embedded terminal — a Claude Code or Codex session, or a plain shell. `projectID`
/// nil is a standalone terminal. The Desktop writes every column; Go writes
/// only an AI-generated title (`watchtower terminal title`) and the hook
/// columns, among them `agent_transcript_path` (00109).
package struct TerminalSession: Codable, FetchableRecord, Identifiable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case claude, codex, shell

        /// The row kind that runs `agent`.
        package init(_ agent: AgentKind) {
            switch agent {
            case .claude: self = .claude
            case .codex: self = .codex
            }
        }

        /// The agent this session runs; nil for a shell.
        package var agent: AgentKind? { AgentKind(rawValue: rawValue) }

        /// Whether this is a coding-agent session (Claude Code or Codex) rather than a shell.
        package var isAgent: Bool { agent != nil }
    }
    package enum TitleSource: String, Codable, Sendable { case auto, ai, user }

    package var id: Int64
    package var projectID: Int64?
    package var kind: Kind
    package var title: String
    package var titleSource: TitleSource
    package var targetID: Int64?
    package var folderPath: String
    /// The agent's own session id (Claude Code or Codex). Nil on a shell, and
    /// on a codex row until its first SessionStart reports the id Codex minted.
    package var claudeSessionID: String?
    package var createdAt: String
    package var lastActiveAt: String
    /// The transcript path the agent's SessionStart hook reported; nil = none.
    package var transcriptPath: String?
    /// The `wt/<slug>` branch of the worktree Watchtower created for this
    /// session (00114); nil = the session runs in the workbench folder or a
    /// checkout Watchtower did not create.
    package var worktreeBranch: String?
    /// The commit that branch was cut from; nil with `worktreeBranch`.
    package var worktreeBase: String?
    /// The automation run that started this session (00122); nil = the owner
    /// started it, or the run was deleted since.
    package var automationRunID: Int64?
    // `closed_at` is a legacy column, no longer read or written: the Close
    // action was removed, so every row is just running or not running.

    package enum CodingKeys: String, CodingKey {
        case id, kind, title
        case projectID = "project_id"
        case titleSource = "title_source"
        case targetID = "target_id"
        case folderPath = "folder_path"
        case claudeSessionID = "claude_session_id"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
        case transcriptPath = "agent_transcript_path"
        case worktreeBranch = "worktree_branch"
        case worktreeBase = "worktree_base"
        case automationRunID = "automation_run_id"
    }
}
