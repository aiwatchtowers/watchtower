import Foundation
import GRDB

/// A `claude` row's recorded main-agent working directory (board #565,
/// migration 00110): `agent_cwd` and its event time `agent_cwd_at`. Go's
/// workbench hooks write both; the Desktop only reads them, in a query of
/// their own (`TerminalSessionQueries.fetchAgentCwds`), so a database
/// without the columns still loads every session.
package struct SessionAgentCwd: Decodable, FetchableRecord, Equatable, Sendable {
    package var sessionID: Int64
    /// Absolute; nil = unknown.
    package var path: String?
    /// `agent_state_at` layout (UTC, milliseconds); nil with `path`.
    package var at: String?

    package init(sessionID: Int64, path: String?, at: String?) {
        self.sessionID = sessionID
        self.path = path
        self.at = at
    }

    package enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case path = "agent_cwd"
        case at = "agent_cwd_at"
    }
}

/// Where a workbench session's agent works (spec
/// 2026-10-12-session-worktree-design §4): the workbench folder, a linked
/// worktree of its repository, a worktree since removed, or not known yet.
/// Built from the row's trusted cwd and `workbench git status --folder`.
package enum SessionPlace: Equatable, Sendable {
    /// No trusted cwd (D10): shown as the main folder, but the branch
    /// switch's agent check counts it as maybe in any worktree.
    case unknown
    /// The workbench folder (also a cwd outside every worktree of the
    /// repository: the page falls back to the main folder).
    case main
    /// A linked worktree; `root` is Go's `folder_root` — the only spelling a
    /// `CodeRoot` may be built from — and `status` its git status.
    case worktree(name: String, root: URL, status: WorkbenchGitStatus)
    /// The cwd no longer exists (`folder_scope: missing`); `path` is it.
    case removed(name: String, path: String)

    /// The cwd the place is derived from, or nil (D10/D11): none recorded;
    /// for a live row, one reported before the run started at `runStart`
    /// (the run's `SessionStart` did not report — an unknown start or an
    /// unreadable stamp is not trusted either). A row that is not live keeps
    /// its last recorded cwd.
    package static func trustedCwd(row: SessionAgentCwd?, runStart: Date?, live: Bool) -> String? {
        guard let path = row?.path, !path.isEmpty else { return nil }
        guard live else { return path }
        guard let runStart, let at = row?.at.flatMap(SessionAgentStatus.parseStamp), at >= runStart else {
            return nil
        }
        return path
    }

    /// Whether `cwd` is the workbench folder itself (lexically), the one
    /// place known without running git. Any other cwd, even one inside the
    /// folder, needs `workbench git status --folder`: a linked worktree may
    /// live there (`.claude/worktrees/<name>`).
    package static func isWorkbenchFolder(_ cwd: String, workbenchFolder: String) -> Bool {
        lexicalPath(cwd) == lexicalPath(workbenchFolder)
    }

    /// The place of a trusted `cwd`, given the `--folder cwd` status
    /// envelope. nil = no verdict (`status` not read yet, or its scope is
    /// unresolved): keep the last known place and treat it as stale.
    package static func resolvePlace(cwd: String?, status: WorkbenchGitStatus?, workbenchFolder: String) -> Self? {
        guard let cwd else { return .unknown }
        if isWorkbenchFolder(cwd, workbenchFolder: workbenchFolder) { return .main }
        guard let status else { return nil }
        switch status.folderScope {
        case .main, .outside: return .main
        case .unresolved: return nil
        case .missing:
            let name = status.worktreeName.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : status.worktreeName
            return .removed(name: name, path: cwd)
        case .worktree:
            let rootPath = status.folderRoot.isEmpty ? cwd : status.folderRoot
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let name = status.worktreeName.isEmpty ? root.lastPathComponent : status.worktreeName
            return .worktree(name: name, root: root, status: status)
        }
    }

    private static func lexicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
