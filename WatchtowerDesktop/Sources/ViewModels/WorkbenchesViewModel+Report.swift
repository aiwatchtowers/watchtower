import Foundation
import WatchtowerCore

/// What the Session view shows (`WorkbenchesViewModel.reportPane`).
enum SessionReportPane: Equatable {
    /// No `claude` session to report on: none picked yet, the one picked
    /// was deleted, or a shell.
    case pickSession
    /// The first run has not answered yet.
    case loading(TerminalSession)
    /// The first run failed: nothing to keep, only its error line.
    case failed(TerminalSession, error: String)
    /// A report; `staleError` is the error line of the run after it.
    case report(TerminalSession, SessionReport, staleError: String?)
}

/// The workbench session report (spec 2026-10-03-workbench-session-report
/// Part 7): the session rows' report line and the Session view, read from
/// `SessionReportCenter`.
extension WorkbenchesViewModel {
    typealias SummarySnapshot = SessionReportCenter.Snapshot<[Int64: SessionReportSummary]>
    typealias ReportSnapshot = SessionReportCenter.Snapshot<SessionReport>

    // MARK: - Session rows

    /// A workbench session row's report line, "#314 · 14/15 · PR #147 open";
    /// nil when its workbench's summary has no line for it.
    func reportLine(sessionID: Int64, projectID: Int64) -> String? {
        Self.reportLine(sessionReports?.summaries[projectID], sessionID: sessionID)
    }

    /// The line from `snapshot`: the last good summary, marked stale when the
    /// run after it failed. Nil before any run succeeded, for a session the
    /// summary does not list, or when there is nothing to say.
    static func reportLine(_ snapshot: SummarySnapshot?, sessionID: Int64) -> String? {
        guard let snapshot, let summary = snapshot.value?[sessionID] else { return nil }
        let caption = SessionReportPresentation.rowCaption(summary, stale: snapshot.isStale)
        return caption.isEmpty ? nil : caption
    }

    /// The row's mini progress bar, done / total (spec Part 1); nil when the
    /// summary has no line for the session or nothing is in scope. A stale
    /// summary keeps the last value, like the line.
    func reportProgress(sessionID: Int64, projectID: Int64) -> Double? {
        Self.reportProgress(sessionReports?.summaries[projectID], sessionID: sessionID)
    }

    static func reportProgress(_ snapshot: SummarySnapshot?, sessionID: Int64) -> Double? {
        guard let summary = snapshot?.value?[sessionID], summary.total > 0 else { return nil }
        return min(max(Double(summary.done) / Double(summary.total), 0), 1)
    }

    /// A workbench's session rows came on screen (the panel): their list
    /// reloads and the center runs their report lines once more.
    func sessionRowsAppeared(projectID: Int64) async {
        sessionReports?.refresh(workbench: projectID)
        await loadSessions(projectID: projectID)
    }

    // MARK: - Session view

    /// The `claude` session a Session view on `sessionID` reports on; nil
    /// when that row is gone or is a shell.
    func reportSession(_ sessionID: Int64, projectID: Int64) -> TerminalSession? {
        session(sessionID, projectID: projectID).flatMap { $0.kind == .claude ? $0 : nil }
    }

    /// What the Session view on `sessionID` shows now.
    func reportPane(sessionID: Int64, projectID: Int64) -> SessionReportPane {
        let session = reportSession(sessionID, projectID: projectID)
        return Self.reportPane(session: session, snapshot: session.flatMap { sessionReports?.reports[$0.id] })
    }

    static func reportPane(session: TerminalSession?, snapshot: ReportSnapshot?) -> SessionReportPane {
        guard let session else { return .pickSession }
        if let report = snapshot?.value { return .report(session, report, staleError: snapshot?.error) }
        if let error = snapshot?.error { return .failed(session, error: error) }
        return .loading(session)
    }

    /// The Session view on `sessionID` is on screen: the center runs that
    /// session's report (and keeps it fresh) while it stays. A pane with no
    /// `claude` session to show runs nothing.
    func reportAppeared(sessionID: Int64, projectID: Int64) {
        guard reportSession(sessionID, projectID: projectID) != nil else { return }
        sessionReports?.show(session: sessionID, workbench: projectID)
    }

    func reportDisappeared(sessionID: Int64) {
        sessionReports?.hide(session: sessionID)
    }

    /// The Session view's session came or went while on screen: a layout
    /// restored before the list loaded gets its row and runs; a deleted
    /// session stops its runs (the pane says "Pick a session").
    func reportSessionChanged(sessionID: Int64, projectID: Int64) {
        if reportSession(sessionID, projectID: projectID) != nil {
            sessionReports?.show(session: sessionID, workbench: projectID)
        } else {
            sessionReports?.hide(session: sessionID)
        }
    }

    /// A target id in the report: the Board goes on screen (beside a
    /// terminal in a split) with that target's card open.
    func showTargetOnBoard(_ targetID: Int64, projectID: Int64) {
        boardFocus[projectID] = targetID
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.showWorkbenchView(.board)
        setLayout(updated, projectID: projectID)
    }

    /// The Board of `projectID` takes the target it should open, once.
    func takeBoardFocus(projectID: Int64) -> Int64? {
        boardFocus.removeValue(forKey: projectID)
    }

    /// A PR row's GitHub page: the workbench's `origin` repository plus
    /// "/pull/<n>". Nil for a branch with no PR, before the remote is read,
    /// or when the remote is not on GitHub — the row is then not a link.
    func pullRequestURL(_ pr: SessionReport.PullRequest, projectID: Int64) -> URL? {
        guard let number = pr.prNumber, case let repository?? = gitHubRepositories[projectID] else { return nil }
        return GitHubRemote.pullRequestURL(repository: repository, number: number)
    }

    /// Reads the workbench folder's `origin` remote once per workbench.
    func loadGitHubRepository(project: Workbench) async {
        guard gitHubRepositories[project.id] == nil, gitHubRepositoryReads.insert(project.id).inserted else { return }
        defer { gitHubRepositoryReads.remove(project.id) }
        let remote = await readOriginRemote(URL(fileURLWithPath: project.folderPath, isDirectory: true))
        gitHubRepositories[project.id] = .some(remote.flatMap(GitHubRemote.repositoryURL(remote:)))
    }
}
