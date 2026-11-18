import Foundation
import GRDB

/// One `terminal_sessions` row (goose migration 00084): a named, resumable
/// embedded terminal — a Claude Code or Codex session, or a plain shell. `projectID`
/// nil is a standalone terminal. The Desktop writes every column; Go writes
/// only an AI-generated title (`watchtower terminal title`) and the hook
/// columns, among them `agent_transcript_path` (00109).
package struct TerminalSession: Codable, FetchableRecord, Identifiable, Equatable, Sendable {
    /// The row's `kind`. A value this build does not know (a newer Mac or
    /// CLI wrote an agent kind this app has no adapter for) decodes as
    /// `unsupported` instead of failing the whole fetch: the row says "not
    /// supported by this version" and never starts, never as Claude Code
    /// and never as a shell (A7b).
    package enum Kind: RawRepresentable, Codable, Hashable, Sendable {
        /// A coding agent this build runs (`AgentKind`: its adapter decides
        /// everything kind-dependent).
        case agent(AgentKind)
        case shell
        /// A kind this build does not know, with its stored value.
        case unsupported(String)

        package static let claude = Self.agent(AgentKind.claude)
        package static let codex = Self.agent(AgentKind.codex)

        package init(rawValue: String) {
            if rawValue == "shell" {
                self = .shell
            } else if let agent = AgentKind(rawValue: rawValue) {
                self = .agent(agent)
            } else {
                self = .unsupported(rawValue)
            }
        }

        package var rawValue: String {
            switch self {
            case let .agent(agent): agent.rawValue
            case .shell: "shell"
            case let .unsupported(raw): raw
            }
        }

        /// The row kind that runs `agent`.
        package init(_ agent: AgentKind) { self = .agent(agent) }

        /// The agent this session runs; nil for a shell and for a kind this
        /// build does not know (`isUnsupported`).
        package var agent: AgentKind? {
            if case let .agent(agent) = self { return agent }
            return nil
        }

        /// Whether this is a coding-agent session (Claude Code or Codex) rather than a shell.
        package var isAgent: Bool { agent != nil }

        /// A kind this build does not know: the row is shown, never started.
        package var isUnsupported: Bool { unsupportedMessage != nil }

        /// A live run of this kind may be a coding agent: an agent kind, or
        /// a kind this build does not know (a newer version's run adopted
        /// from the session host). The safety checks that hold off while an
        /// agent works (the branch switch's guard, session placement) count
        /// it; everything that runs or reads an agent asks `agent`.
        package var mayRunAgent: Bool { isAgent || isUnsupported }

        /// What the row, the session pane and the Workchat say for a kind
        /// this build does not know; nil for every known kind.
        package var unsupportedMessage: String? {
            guard case let .unsupported(raw) = self else { return nil }
            return Self.unsupportedMessage(raw)
        }

        /// The not-supported line for a stored kind `raw`.
        package static func unsupportedMessage(_ raw: String) -> String {
            "This session runs \(raw.isEmpty ? "an agent" : "“\(raw)”"), which this version of Watchtower "
                + "does not support. Update Watchtower to open it."
        }
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
    /// The workbench folder the session was started for (00196); nil for a
    /// standalone terminal. Its cwd is that folder or a worktree of it.
    package var workbenchFolderID: Int64?
    /// The session this one is a sub-session of (00196); nil = a top-level
    /// session, or its parent was deleted since.
    package var parentSessionID: Int64?
    /// That run's trigger (`automation_runs.trigger`, joined by
    /// `TerminalSessionQueries`); nil without a run, or from a read that did
    /// not join it.
    package var automationRunTrigger: String?
    /// Whether that run was claimed (under consent, for a background
    /// trigger); nil without a run or from a read that did not join it
    /// (optional so a row read without the join still decodes).
    package var automationRunClaimed: Bool? // swiftlint:disable:this discouraged_optional_boolean
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
        case workbenchFolderID = "workbench_folder_id"
        case parentSessionID = "parent_session_id"
        case automationRunTrigger = "automation_run_trigger"
        case automationRunClaimed = "automation_run_claimed"
    }

    /// Whether background work started this session: a run of a background
    /// trigger (spec §2.2). The owner's own sessions and those of runs the
    /// owner triggered (Run now, a button, a reply) are not. A run whose
    /// trigger was not read counts as background (fail closed).
    package var isBackgroundRunSession: Bool {
        guard automationRunID != nil else { return false }
        guard let automationRunTrigger else { return true }
        return BackgroundAIConsent.backgroundRunTriggers.contains(automationRunTrigger)
    }

    /// The background AI origin the agent of this session carries (Go
    /// `sessionstart.originEnv`): a claimed background run's session is
    /// admitted as unit `run:<id>`, since its run was claimed under consent
    /// and finishes even when the owner pauses meanwhile; an unclaimed one
    /// (queued, or cancelled before it started, the paused hold included)
    /// is background, not admitted; any other carries none.
    package var agentOriginEnvironment: [String] {
        guard isBackgroundRunSession, let automationRunID else { return [] }
        guard automationRunClaimed == true else { return ["\(CLIOrigin.environmentKey)=background"] }
        return BackgroundAIConsent.admittedEnvironment(unit: "run:\(automationRunID)")
    }
}
