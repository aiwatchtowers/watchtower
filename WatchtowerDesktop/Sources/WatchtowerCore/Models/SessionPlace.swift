import Foundation
import GRDB

/// A `claude` row's recorded main-agent working directory (board #565,
/// migration 00110): `agent_cwd` and its event time `agent_cwd_at`, with the
/// start of the run it is judged against — the run mark's stamp,
/// `agent_turns`' `since`, read as Go's `db.TerminalAgentCwd` reads it. Go's
/// workbench hooks write all three; the Desktop only reads them, in a query
/// of its own (`TerminalSessionQueries.fetchAgentCwds`), so a database
/// without the columns still loads every session.
package struct SessionAgentCwd: Decodable, FetchableRecord, Equatable, Sendable {
    package var sessionID: Int64
    /// Absolute; nil = unknown.
    package var path: String?
    /// `agent_state_at` layout (UTC, milliseconds); nil with `path`.
    package var at: String?
    /// The run mark's stamp (`agent_turns.since`, same layout); nil when the
    /// row has no run mark or `agent_turns` is not JSON.
    package var runStart: String?

    package init(sessionID: Int64, path: String?, at: String?, runStart: String? = nil) {
        self.sessionID = sessionID
        self.path = path
        self.at = at
        self.runStart = runStart
    }

    package enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case path = "agent_cwd"
        case at = "agent_cwd_at"
        case runStart = "run_start"
    }
}

/// Where a workbench session's agent works (spec
/// 2026-10-12-session-worktree-design §4): the workbench folder, a linked
/// worktree of its repository, a worktree since removed, or not known yet.
/// Built from the row's trusted cwd and `workbench git status --folder`.
package enum SessionPlace: Equatable, Sendable {
    /// No trusted cwd (D10), or a missing cwd not proven to have been a
    /// worktree: shown as the main folder, but the branch switch's agent
    /// check counts it as maybe in any worktree.
    case unknown
    /// The workbench folder (also a cwd outside every worktree of the
    /// repository: the page falls back to the main folder).
    case main
    /// A linked worktree; `root` is Go's `folder_root` — the only spelling a
    /// `CodeRoot` may be built from — and `status` its git status.
    case worktree(name: String, root: URL, status: WorkbenchGitStatus)
    /// The cwd no longer exists (`folder_scope: missing`) and was in the
    /// worktree `name`; `path` is the cwd. The agent check counts it as maybe
    /// in any worktree, as `unknown`.
    case removed(name: String, path: String)

    /// The cwd the place is derived from, or nil (D10/D11): none recorded;
    /// for a live row, one reported before the row's own run start
    /// (`row.runStart`, the run mark Go's hooks judge a cwd against — the
    /// run's `SessionStart` did not report). Go's `AgentCwd.WouldRecord`
    /// boundary: a cwd stamped at the run start or later belongs to the run.
    /// Fail closed where Go would not block: a live row without a readable
    /// run start or cwd stamp is not trusted. A row that is not live keeps
    /// its last recorded cwd.
    package static func trustedCwd(row: SessionAgentCwd?, live: Bool) -> String? {
        guard let row, let path = row.path, !path.isEmpty else { return nil }
        guard live else { return path }
        guard let runStart = row.runStart.flatMap(SessionAgentStatus.parseStamp),
              let at = row.at.flatMap(SessionAgentStatus.parseStamp), at >= runStart else {
            return nil
        }
        return path
    }

    /// Whether `cwd` is the workbench folder itself (lexically), the one
    /// place known without running git. Any other cwd, even one inside the
    /// folder, needs `workbench git status --folder cwd`: a linked worktree
    /// may live there (`.claude/worktrees/<name>`).
    package static func isWorkbenchFolder(_ cwd: String, workbenchFolder: String) -> Bool {
        lexicalPath(cwd) == lexicalPath(workbenchFolder)
    }

    /// The place of a trusted `cwd`, given the `--folder cwd` status
    /// envelope. Fail closed — an unproven place is never `.main`. nil = no
    /// verdict, keep the last known place and treat it as stale: `status`
    /// not read yet, unresolved, or not asked about this cwd (its
    /// `folder_requested` is another folder or empty — the header's own
    /// status never places a session). `last` is the place known before
    /// this read: a missing cwd is a removed worktree only when it was one
    /// (`removedPlace`).
    package static func resolvePlace(
        cwd: String?,
        status: WorkbenchGitStatus?,
        workbenchFolder: String,
        last: Self? = nil
    ) -> Self? {
        guard let cwd else { return .unknown }
        if isWorkbenchFolder(cwd, workbenchFolder: workbenchFolder) { return .main }
        guard let status, isAnswer(status, about: cwd) else { return nil }
        switch status.folderScope {
        case .main, .outside: return .main
        case .unresolved: return nil
        case .missing: return removedPlace(cwd: cwd, last: last) ?? .unknown
        case .worktree:
            let rootPath = status.folderRoot.isEmpty ? cwd : status.folderRoot
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let name = status.worktreeName.isEmpty ? root.lastPathComponent : status.worktreeName
            return .worktree(name: name, root: root, status: status)
        }
    }

    /// Whether `status` answers `--folder cwd`: Go echoes the flag verbatim
    /// as `folder_requested`; compared lexically, as `isWorkbenchFolder`.
    private static func isAnswer(_ status: WorkbenchGitStatus, about cwd: String) -> Bool {
        !status.folderRequested.isEmpty && lexicalPath(status.folderRequested) == lexicalPath(cwd)
    }

    /// The removed worktree a missing `cwd` was in, named after the
    /// worktree (never the cwd's own last component): the last known
    /// worktree or removed place holding it, else a `.claude/worktrees/<name>`
    /// folder in its path. nil — not proven a worktree — reads as unknown.
    private static func removedPlace(cwd: String, last: Self?) -> Self? {
        switch last {
        case let .worktree(name, root, _) where isWithin(cwd, root.path):
            return .removed(name: name, path: cwd)
        case let .removed(name, path) where isWithin(cwd, path):
            return .removed(name: name, path: cwd)
        default:
            break
        }
        let parts = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents
        for index in parts.indices.dropLast(2) where parts[index] == ".claude" && parts[index + 1] == "worktrees" {
            return .removed(name: parts[index + 2], path: cwd)
        }
        return nil
    }

    private static func isWithin(_ path: String, _ base: String) -> Bool {
        let path = lexicalPath(path), base = lexicalPath(base)
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private static func lexicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
