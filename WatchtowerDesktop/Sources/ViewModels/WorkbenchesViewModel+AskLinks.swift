import Foundation
import WatchtowerCore

/// Workbench paths clicked in an ask's text (#394, board #565): resolved in
/// the root of the ask's session and opened where the page shows them.
extension WorkbenchesViewModel {
    /// A workbench path clicked in an ask's text (#394): the file in Files
    /// at the line, beside the terminal (a terminal link's placement); an
    /// expanded drawer goes back beside it so the file shows. The file
    /// opens by its resolved path, so `./a.go` and `a.go` are one tab.
    /// False — and nothing opened — for a path that is not a file of the
    /// folder or a workbench no longer listed. The folder is the root of
    /// the ask's session (its worktree when proven), else the page's; the
    /// file always opens where the page shows it (`askLinkRoot`).
    @discardableResult
    func openAskLink(_ target: OpenQuicklyTarget, projectID: Int64, sessionID: Int64? = nil) async -> Bool {
        guard let project = summaries.first(where: { $0.id == projectID })?.project,
              let place = await askLinkRoot(target.path, project: project, sessionID: sessionID) else { return false }
        asks.drawerExpanded = false
        let opened = OpenQuicklyTarget(path: place.path, line: target.line, col: target.col)
        await openFile(at: opened, root: place.root, beside: true)
        return true
    }

    /// Where an ask's path opens: the ask session's root when its place is
    /// proven and the page shows it. Otherwise that session is brought onto
    /// the page first and its place awaited (a session just resumed has
    /// none until its hook reports, `askPlaceTimeout`); still unproven, its
    /// last proven worktree when the file is there. A session that cannot
    /// come onto the page leaves the page's root, when the same path is a
    /// file there. nil: nothing to open (the caller beeps).
    private func askLinkRoot(
        _ rawPath: String, project: Workbench, sessionID: Int64?
    ) async -> (root: CodeRoot, path: String)? {
        let pageRoot = activeCodeRoot(project: project)
        guard let sessionID else { return Self.fileOf(rawPath, in: pageRoot) }
        let askRoot = codeRoot(sessionID: sessionID, project: project)
        if askRoot == pageRoot, sessionPlaces.isPlaceProven(sessionID: sessionID) {
            return Self.fileOf(rawPath, in: askRoot)
        }
        guard await bringSessionOnPage(sessionID, projectID: project.id) else {
            guard let path = Self.fileOf(rawPath, in: askRoot)?.path else { return nil }
            return Self.fileOf(path, in: activeCodeRoot(project: project)).flatMap { $0.path == path ? $0 : nil }
        }
        let proven = await sessionPlaces.awaitProvenPlace(
            sessionID: sessionID, workbenchID: project.id, folder: project.folderPath, timeout: askPlaceTimeout
        )
        guard proven else { return lastWorktreeFile(rawPath, sessionID: sessionID, project: project) }
        return provenAskFile(rawPath, sessionID: sessionID, project: project)
    }

    /// The session's proven root holds the file: there when the page shows
    /// that root, else on the page when the same path is a file there.
    private func provenAskFile(
        _ rawPath: String, sessionID: Int64, project: Workbench
    ) -> (root: CodeRoot, path: String)? {
        let root = codeRoot(sessionID: sessionID, project: project)
        guard let found = Self.fileOf(rawPath, in: root) else { return nil }
        let shown = activeCodeRoot(project: project)
        guard root != shown else { return found }
        return Self.fileOf(found.path, in: shown).flatMap { $0.path == found.path ? $0 : nil }
    }

    /// The session's last proven worktree, when it still holds the file.
    private func lastWorktreeFile(
        _ rawPath: String, sessionID: Int64, project: Workbench
    ) -> (root: CodeRoot, path: String)? {
        guard let last = lastWorktreeRoots[CodeRootMemoKey(projectID: project.id, sessionID: sessionID)],
              !codeFiles.isRemoved(last) else { return nil }
        return Self.fileOf(rawPath, in: last)
    }

    private static func fileOf(_ rawPath: String, in root: CodeRoot) -> (root: CodeRoot, path: String)? {
        WorkbenchFolderPath.resolve(rawPath, folder: root.folder.path).map { (root, $0) }
    }

    /// Puts a workbench session on its page the way a panel click does
    /// (one not running resumes). False when its row is gone.
    private func bringSessionOnPage(_ sessionID: Int64, projectID: Int64) async -> Bool {
        if session(sessionID, projectID: projectID) == nil {
            guard await loadSessions(projectID: projectID) else { return false }
        }
        guard let row = session(sessionID, projectID: projectID) else { return false }
        await open(row)
        return layout(projectID: projectID).sessionIDs.contains(sessionID)
    }
}
