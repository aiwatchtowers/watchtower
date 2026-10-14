import Foundation
import WatchtowerCore

/// The automatic end of a placed session (spec
/// 2026-10-14-session-worktrees-design.md §9, PROJ-18 amended): once the
/// agent of a finished row with a `worktree_branch` exits, #535's cleanup
/// runs through `SessionCleanupCenter` for exactly two items — the row's own
/// worktree and its `wt/` branch — and the removed worktree's local MCP entry
/// is forgotten. The agent cannot do it itself: its cwd is inside the
/// worktree, which keeps it.
///
/// It removes files without asking, so it never acts on anything else and
/// steps aside whenever another cleanup or a delete owns the row, or the row
/// is live again. Go keeps an item for every PROJ-18 catch and records why
/// (`cleanup_result`, the report's Cleanup line); a kept worktree waits for a
/// later cleanup. Nothing here is shown on the page: failures are logged.
extension WorkbenchesViewModel {
    /// The exit hook's part: starts the cleanup of session `id` in a run
    /// this view model owns (`placedCleanupRuns`), unless one runs already.
    /// Which rows qualify is decided inside the run, from a fresh read.
    func startPlacedCleanup(sessionID id: Int64) {
        guard sessionCleanup != nil, placedCleanupRuns[id] == nil else { return }
        placedCleanupRuns[id] = Task {
            await self.cleanUpPlacedWorktree(sessionID: id)
            self.placedCleanupRuns[id] = nil
        }
    }

    private func cleanUpPlacedWorktree(sessionID id: Int64) async {
        do {
            guard let row = try await dbPool.read({ try TerminalSessionQueries.fetch($0, id: id) }) else { return }
            await cleanUpPlacedWorktree(row)
        } catch {
            NSLog("WorkbenchesViewModel: reading session %lld for its worktree cleanup failed: %@",
                  id, error.localizedDescription)
        }
    }

    /// Cleans up finished placed session `row` after its agent exited: plans
    /// as the Delete dialog does (`closingSession`), applies only the plan's
    /// pending removals among the row's own worktree and branch, and
    /// forgets that worktree's MCP entry once it was removed. Nothing for a
    /// row without `worktreeBranch` or a workbench, one not finished, or one
    /// live again — checked once more right before the apply.
    func cleanUpPlacedWorktree(_ row: TerminalSession) async {
        guard let branch = row.worktreeBranch, let workbenchID = row.projectID, let center = sessionCleanup,
              await mayCleanUpPlaced(row, center: center, phase: .idle) else { return }
        let scope = SessionCleanupScope.session(row.id)
        await center.planCleanup(sessionID: row.id, workbenchID: workbenchID, closingSession: true)
        let planned = center.cleanupPhase(for: scope)
        guard case let .ready(plan) = planned else {
            if case let .failed(message) = planned {
                NSLog("WorkbenchesViewModel: planning session %lld's worktree cleanup failed: %@", row.id, message)
                center.forgetCleanup(scope)
            }
            // Anything else: another plan for the row superseded this one.
            return
        }
        let items = Self.placedCleanupItems(in: plan, folderPath: row.folderPath, branch: branch)
        guard !items.isEmpty, await mayCleanUpPlaced(row, center: center, phase: planned) else {
            forgetCleanup(scope, ifStill: planned, center: center)
            return
        }
        cleaningUpSessions.insert(row.id)
        let ok = await center.applyCleanup(sessionID: row.id, workbenchID: workbenchID, items: items.map(\.key))
        cleaningUpSessions.remove(row.id)
        let applied = center.cleanupPhase(for: scope)
        if !ok {
            NSLog("WorkbenchesViewModel: session %lld's worktree cleanup failed: %@",
                  row.id, center.failureText(for: scope) ?? "unknown error")
        }
        if case let .done(result) = applied, let tree = items.first(where: { $0.kind == .worktree }),
           result.items.contains(where: { $0.key == tree.key && $0.done }) {
            await forgetPlacedWorktree(String(tree.key.dropFirst(Self.worktreeKeyPrefix.count)), workbenchID: workbenchID)
        }
        forgetCleanup(scope, ifStill: applied, center: center)
        await loadCleanupRecord(sessionID: row.id)
    }

    private static let worktreeKeyPrefix = "worktree:"

    /// The plan's pending removals among the session's own two items: the
    /// worktree whose root is the longest one containing `folderPath`
    /// (chosen before its action is looked at, so a kept own worktree never
    /// lets an enclosing one through) and `branch:<branch>`.
    private static func placedCleanupItems(
        in plan: SessionCleanupPlan, folderPath: String, branch: String
    ) -> [SessionCleanupItem] {
        let own = plan.items
            .filter { $0.kind == .worktree && $0.key.hasPrefix(worktreeKeyPrefix) }
            .filter { item in
                let root = String(item.key.dropFirst(worktreeKeyPrefix.count))
                guard !root.isEmpty else { return false }
                return folderPath == root || folderPath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            .max { $0.key.count < $1.key.count }
        let ownBranch = plan.items.first { $0.kind == .branch && $0.key == "branch:\(branch)" }
        return [own, ownBranch].compactMap { $0 }.filter(\.isPendingRemoval)
    }

    /// Whether the automatic cleanup may go on for `row`: its terminal is
    /// not live, no other cleanup, sheet or delete owns it, the scope is
    /// still in `phase` (what this run left), and — read fresh — the row is
    /// finished. A failed read is logged and stops it.
    private func mayCleanUpPlaced(_ row: TerminalSession, center: SessionCleanupCenter, phase: SessionCleanupPhase) async -> Bool {
        let id = row.id
        guard terminalCenter?.liveIDs.contains(id) != true, !cleaningUpSessions.contains(id),
              cleanupRuns[id] == nil, !openCleanupSheets.contains(id), !closingDeletes.contains(id),
              !pendingDeletes.ids.contains(id), center.cleanupPhase(for: .session(id)) == phase else { return false }
        do {
            let finished = try await dbPool.read { try TerminalSessionQueries.isFinished($0, id: id) }
            // The read awaited: a resume meanwhile wins.
            return finished && terminalCenter?.liveIDs.contains(id) != true
        } catch {
            NSLog("WorkbenchesViewModel: reading whether session %lld finished failed: %@", id, error.localizedDescription)
            return false
        }
    }

    /// Forgets `scope` only while it still holds what this run left there:
    /// a Delete dialog or sheet that took the scope over keeps its phase.
    private func forgetCleanup(_ scope: SessionCleanupScope, ifStill phase: SessionCleanupPhase, center: SessionCleanupCenter) {
        if center.cleanupPhase(for: scope) == phase { center.forgetCleanup(scope) }
    }

    /// Drops the removed worktree at `root` from the workbench's local MCP
    /// registrations. Best effort: a failure is logged, never shown.
    private func forgetPlacedWorktree(_ root: String, workbenchID: Int64) async {
        guard let cli else { return }
        do {
            let result = try await cli.worktreeForget(projectID: workbenchID, path: root)
            if !result.error.isEmpty {
                NSLog("WorkbenchesViewModel: forgetting worktree %@ failed: %@", root, result.error)
            }
        } catch {
            NSLog("WorkbenchesViewModel: forgetting worktree %@ failed: %@", root, error.localizedDescription)
        }
    }
}
