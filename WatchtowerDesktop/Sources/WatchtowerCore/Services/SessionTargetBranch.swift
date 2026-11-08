import Foundation

/// The branch a workbench session's work merges into (board #987): the
/// session row leads with it instead of the branch of the folder the
/// agent's own terminal sits in — a controller that sends subagents to
/// lane worktrees stays in the main folder while the work lands on the
/// target's branch. Pure; the board tree is the one the row menu's
/// **Session Target ▸** already holds.
package enum SessionTargetBranch: Equatable, Sendable {
    /// One branch (PROJ-07's `targets.branch`).
    case one(String)
    /// Distinct branches, sorted.
    case several([String])

    /// A target's parent and its own branch ("" = not linked).
    package struct Entry: Equatable, Sendable {
        package let parentID: Int64?
        package let branch: String

        package init(parentID: Int64?, branch: String) {
            self.parentID = parentID
            self.branch = branch
        }
    }

    /// Every target of `roots`' tree by id.
    package static func index(_ roots: [WorkbenchBoardNode]) -> [Int64: Entry] {
        var entries: [Int64: Entry] = [:]
        var stack = roots
        while let node = stack.popLast() {
            entries[Int64(node.target.id)] = Entry(parentID: node.target.parentId.map(Int64.init), branch: node.target.branch)
            stack.append(contentsOf: node.children)
        }
        return entries
    }

    /// The session's target branch: the bound target's effective branch
    /// when the session is bound; else the distinct effective branches of
    /// the targets its agent linked (`terminal_session_targets`). nil when
    /// none has one. A target not on the board counts for nothing.
    package static func resolve(boundTargetID: Int64?, linkedTargetIDs: [Int64], targets: [Int64: Entry]) -> Self? {
        let ids = boundTargetID.map { [$0] } ?? linkedTargetIDs
        let branches = Set(ids.compactMap { effectiveBranch(of: $0, targets: targets) }).sorted()
        switch branches.count {
        case 0: return nil
        case 1: return .one(branches[0])
        default: return .several(branches)
        }
    }

    /// The target's own branch, else its nearest ancestor's (a leaf under a
    /// feature group works on the group's branch); nil when none has one.
    /// A cycle in the parents ends the walk.
    package static func effectiveBranch(of targetID: Int64, targets: [Int64: Entry]) -> String? {
        var seen: Set<Int64> = []
        var current: Int64? = targetID
        while let id = current, seen.insert(id).inserted, let entry = targets[id] {
            let branch = entry.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty { return branch }
            current = entry.parentID
        }
        return nil
    }
}

/// The lane worktrees of a workbench session (board #987): the worktree
/// roots its agents — subagents and teammates included — worked in this
/// run, as the state hooks recorded them in `terminal_session_worktrees`
/// (migration 00111). Pure: the existence check and the workbench folder's
/// symlink-resolved spelling are the caller's, read off the main actor.
package enum SessionLanes {
    /// One ledger row: a symlink-resolved worktree root and when the hooks
    /// last saw it in a run (`last_at`, else `first_at`; `agent_state_at`
    /// layout). The hooks move `last_at` once per run that sees the row
    /// again (board #1018), so a lane a later run reuses counts in it.
    package struct Record: Equatable, Sendable {
        package let root: String
        package let seenAt: String

        package init(root: String, seenAt: String) {
            self.root = root
            self.seenAt = seenAt
        }
    }

    /// The distinct roots, sorted, that were last seen at or after `runStart`
    /// (the row's run mark; none without a readable one), that
    /// still exist, and that are not the agent's own checkout: a ledger root
    /// is a worktree's top level, so a root holding the workbench folder is
    /// the main checkout and a root holding the place's folder (a worktree
    /// place's `folder_root` may be a subfolder of its top level, or the
    /// removed cwd) is the agent's own worktree. An unknown place could be
    /// any of them: no lanes until it is known (fail closed).
    ///
    /// The ledger holds symlink-resolved roots, so the workbench folder is
    /// also matched in `resolvedWorkbenchFolder` (`resolvedFolder`, which
    /// the caller reads off the main actor). A worktree place's root is Go's
    /// `folder_root`, already resolved; a removed place's path is the
    /// agent's own cwd, which no longer exists to resolve.
    package static func roots(
        _ records: [Record],
        runStart: String?,
        workbenchFolder: String,
        resolvedWorkbenchFolder: String? = nil,
        place: SessionPlace,
        exists: (String) -> Bool
    ) -> [String] {
        var held = [workbenchFolder] + (resolvedWorkbenchFolder.map { [$0] } ?? [])
        switch place {
        case .unknown: return []
        case .main: break
        case let .worktree(_, root, _): held.append(root.path)
        case let .removed(_, path): held.append(path)
        }
        guard let start = runStart.flatMap(SessionAgentStatus.parseStamp) else { return [] }
        var roots: Set<String> = []
        for record in records {
            guard let seen = SessionAgentStatus.parseStamp(record.seenAt), seen >= start else { continue }
            let root = normalized(record.root)
            guard !held.contains(where: { isWithin($0, root) }) else { continue }
            roots.insert(root)
        }
        return roots.filter(exists).sorted()
    }

    /// The lexical spelling `roots` compares and returns (and so the one
    /// its `exists` is asked about).
    package static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// `path` with its symlinks resolved (file system calls: keep it off
    /// the main actor).
    package static func resolvedFolder(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isWithin(_ path: String, _ base: String) -> Bool {
        let path = normalized(path), base = normalized(base)
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

/// One session's rows behind its target branch and lanes
/// (`TerminalSessionQueries.fetchWorkLinks`).
package struct SessionWorkLinks: Equatable, Sendable {
    package var linkedTargetIDs: [Int64] = []
    package var worktrees: [SessionLanes.Record] = []
    /// The run mark's stamp; nil without one (or without a worktree row).
    package var runStart: String?

    package init(linkedTargetIDs: [Int64] = [], worktrees: [SessionLanes.Record] = [], runStart: String? = nil) {
        self.linkedTargetIDs = linkedTargetIDs
        self.worktrees = worktrees
        self.runStart = runStart
    }
}
