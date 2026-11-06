import Foundation
import GRDB
import WatchtowerCore

/// A workbench's session work links (board #987) with the ledger roots
/// still on disk, read off the main actor: the row's place line counts the
/// lanes from it without a stat of its own.
struct SessionWorkSnapshot: Equatable {
    let links: [Int64: SessionWorkLinks]
    let workbenchFolder: String
    /// Ledger roots (`SessionLanes.normalized`) that existed at the read.
    let existingRoots: Set<String>

    /// Session `sessionID`'s lane worktrees beside its agent's own `place`.
    func lanes(of sessionID: Int64, place: SessionPlace) -> [String] {
        guard let links = links[sessionID] else { return [] }
        var placeRoot: String?
        if case let .worktree(_, root, _) = place { placeRoot = root.path }
        return SessionLanes.roots(
            links.worktrees, runStart: links.runStart, workbenchFolder: workbenchFolder,
            placeRoot: placeRoot, exists: existingRoots.contains
        )
    }
}

extension WorkbenchesViewModel {
    /// Reads workbench `projectID`'s session work links and stats their
    /// worktree roots off the main actor. A failed read keeps the last
    /// snapshot (logged): the line then shows the last known lanes. Only
    /// the latest read started applies, so an older one never undoes it.
    func loadSessionWork(projectID: Int64) async {
        let read = sessionWorkReads[projectID, default: 0] + 1
        sessionWorkReads[projectID] = read
        do {
            let (links, folder) = try await dbPool.read { db in
                (try TerminalSessionQueries.fetchWorkLinks(db, projectID: projectID),
                 try WorkbenchQueries.fetch(db, id: projectID)?.folderPath)
            }
            guard read == sessionWorkReads[projectID] else { return }
            guard let folder else {
                sessionWork[projectID] = nil
                return
            }
            let roots = Set(links.values.flatMap { $0.worktrees.map { SessionLanes.normalized($0.root) } })
            let existing = await Task.detached(priority: .utility) {
                Set(roots.filter { CodeRootPolicy.directoryExists(URL(fileURLWithPath: $0, isDirectory: true)) })
            }.value
            guard read == sessionWorkReads[projectID] else { return }
            sessionWork[projectID] = SessionWorkSnapshot(links: links, workbenchFolder: folder, existingRoots: existing)
        } catch {
            NSLog("WorkbenchesViewModel: could not read the session work links of workbench %lld: %@",
                  projectID, error.localizedDescription)
        }
    }

    /// The session states changed (a run started or stopped, an agent moved):
    /// every listed workbench's work links are read again.
    func reloadSessionWork() {
        for projectID in terminalSessions.keys {
            Task { await loadSessionWork(projectID: projectID) }
        }
    }
}
