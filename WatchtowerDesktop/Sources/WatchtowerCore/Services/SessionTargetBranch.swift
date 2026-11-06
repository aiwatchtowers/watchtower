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
/// (migration 00111). Pure; the existence check is the caller's stat.
package enum SessionLanes {
    /// One ledger row: a symlink-resolved worktree root and when the hooks
    /// first saw it (`agent_state_at` layout).
    package struct Record: Equatable, Sendable {
        package let root: String
        package let firstAt: String

        package init(root: String, firstAt: String) {
            self.root = root
            self.firstAt = firstAt
        }
    }

    /// The distinct roots, sorted, that were first seen at or after
    /// `runStart` (the row's run mark; none without a readable one), are not
    /// the workbench's own checkout (a root holding `workbenchFolder`), are
    /// not `placeRoot` (the agent's own worktree) and still exist.
    package static func roots(
        _ records: [Record],
        runStart: String?,
        workbenchFolder: String,
        placeRoot: String?,
        exists: (String) -> Bool
    ) -> [String] {
        guard let start = runStart.flatMap(SessionAgentStatus.parseStamp) else { return [] }
        let folders = [workbenchFolder, resolved(workbenchFolder)]
        let own = placeRoot.map { [normalized($0), resolved($0)] } ?? []
        var roots: Set<String> = []
        for record in records {
            guard let seen = SessionAgentStatus.parseStamp(record.firstAt), seen >= start else { continue }
            let root = normalized(record.root)
            guard !own.contains(root), !folders.contains(where: { isWithin($0, root) }) else { continue }
            roots.insert(root)
        }
        return roots.filter(exists).sorted()
    }

    /// The lexical spelling `roots` compares and returns (and so the one
    /// its `exists` is asked about).
    package static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func resolved(_ path: String) -> String {
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
