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
    /// A click superseded by a newer one (`clickAskLink`) opens nothing.
    @discardableResult
    func openAskLink(_ target: OpenQuicklyTarget, projectID: Int64, sessionID: Int64? = nil) async -> Bool {
        guard let project = summaries.first(where: { $0.id == projectID })?.project,
              let place = await askLinkRoot(target.path, project: project, sessionID: sessionID),
              !Task.isCancelled else { return false }
        let opened = OpenQuicklyTarget(path: place.path, line: target.line, col: target.col)
        await openFile(at: opened, root: place.root, beside: true)
        // After the open: collapsing the drawer may take the clicked view
        // (and its link task) away.
        asks.drawerExpanded = false
        return true
    }

    /// A path clicked in an ask's text (`OwnerAskLinks`): one link in
    /// flight per workbench — a newer click cancels the one still waiting
    /// for its session's place, and so does the view that started it going
    /// away (`cancelAskLink`, by `owner`). `beep` when it opened nothing and
    /// was not cancelled.
    @discardableResult
    func clickAskLink(
        _ target: OpenQuicklyTarget,
        projectID: Int64,
        sessionID: Int64?,
        owner: UUID = UUID(),
        beep: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        askLinkTasks[projectID]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let opened = await self.openAskLink(target, projectID: projectID, sessionID: sessionID)
            if askLinkTasks[projectID]?.token == token { askLinkTasks[projectID] = nil }
            if !opened, !Task.isCancelled { beep() }
        }
        askLinkTasks[projectID] = AskLinkInFlight(token: token, owner: owner, task: task)
        return task
    }

    /// The ask view `owner` went away: the link it started, still waiting,
    /// opens nothing. A link another view of the workbench started runs on.
    func cancelAskLink(projectID: Int64, owner: UUID) {
        guard askLinkTasks[projectID]?.owner == owner else { return }
        askLinkTasks.removeValue(forKey: projectID)?.task.cancel()
    }

    /// Where an ask's path opens: the ask session's root when its place is
    /// proven and the page shows it. Otherwise that session is brought onto
    /// the page first and its place awaited (a session just resumed has
    /// none until its hook reports, `askPlaceTimeout`). Still unproven, or
    /// a session that cannot come onto the page: the root the page shows,
    /// when the path is a file there — never a tab in a root not on
    /// screen. nil: nothing to open (the caller beeps).
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
        guard !Task.isCancelled else { return nil }
        guard proven else { return Self.fileOf(rawPath, in: activeCodeRoot(project: project)) }
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

/// An ask link in flight (`clickAskLink`): `token` tells a newer click's
/// task from it, `owner` is the ask view that started it.
struct AskLinkInFlight {
    let token: UUID
    let owner: UUID
    let task: Task<Void, Never>
}
