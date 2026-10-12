import Foundation
import GRDB
import WatchtowerCore

/// The sessions' places (board #565): the place line under each agent
/// session's row and the header's worktree crumb. `SessionPlaceCenter`
/// holds them; this wires it to the database, the CLI and the page.
extension WorkbenchesViewModel {
    struct PlaceCLIMissing: LocalizedError {
        var errorDescription: String? { WorkbenchesViewModel.cliMissingMessage }
    }

    /// The center on the database's reader connections (`fetchAgentCwds`
    /// only through `DatabasePool.read`) and `workbench git status --folder`.
    static func makeSessionPlaces(
        dbPool: DatabasePool,
        cli: WorkbenchCLI?,
        terminalCenter: TerminalCenter?
    ) -> SessionPlaceCenter {
        SessionPlaceCenter(
            readCwds: { [dbPool] workbenchID in
                try await dbPool.read { try TerminalSessionQueries.fetchAgentCwds($0, projectID: workbenchID) }
            },
            readStatus: { workbenchID, folder in
                guard let cli else { throw PlaceCLIMissing() }
                return try await cli.gitStatus(projectID: workbenchID, folder: folder)
            },
            isLive: { [weak terminalCenter] id in terminalCenter?.liveIDs.contains(id) ?? false }
        )
    }

    /// `sessions` (in the panel's order) as the panel and the switchers
    /// show them: state, caption, `#id` badge, the agent's place.
    func sessionRows(_ sessions: [TerminalSession]) -> [SessionSwitcherPresentation.Row] {
        SessionSwitcherPresentation.rows(
            sessions, liveIDs: terminalCenter?.liveIDs ?? [], statuses: sessionStatuses, now: now(),
            places: sessionPlaceLabels(sessions)
        )
    }

    /// The place line of each agent session of a workbench (a shell has no
    /// hook to report where it works, a standalone terminal no workbench).
    func sessionPlaceLabels(_ sessions: [TerminalSession]) -> [Int64: SessionPlacePresentation.PlaceLabel] {
        var labels: [Int64: SessionPlacePresentation.PlaceLabel] = [:]
        for session in sessions where session.kind.agent != nil {
            guard let projectID = session.projectID else { continue }
            labels[session.id] = sessionPlaceLabel(sessionID: session.id, projectID: projectID)
        }
        return labels
    }

    /// The header's worktree crumb: the place of the session on screen when
    /// it is a worktree (with its folder, for Show in Finder) or a removed
    /// one; nil for the main folder, an unknown place or a page without a
    /// session.
    func headerPlace(projectID: Int64) -> (label: SessionPlacePresentation.PlaceLabel, folder: URL?)? {
        guard let sessionID = pageSessionID(projectID: projectID) else { return nil }
        switch sessionPlaces.currentPlace(sessionID: sessionID) {
        case let .worktree(_, root, _):
            return (sessionPlaceLabel(sessionID: sessionID, projectID: projectID), root)
        case .removed:
            return (sessionPlaceLabel(sessionID: sessionID, projectID: projectID), nil)
        case .main, .unknown:
            return nil
        }
    }

    /// The code root the page's FILES, Files pane, git marks and code
    /// navigation work in (spec D6, §6.3): the worktree of the session the
    /// layout holds, when its place is a worktree that was read and still
    /// exists; the main folder for a page without a session, a main, unknown,
    /// stale or removed place (never a worktree that cannot be proven). The
    /// worktree root is built only from Go's `folder_root` spelling.
    func activeCodeRoot(project: Workbench) -> CodeRoot {
        guard let sessionID = pageSessionID(projectID: project.id), !sessionPlaces.isPlaceStale(sessionID: sessionID),
              case let .worktree(_, folder, _) = sessionPlaces.currentPlace(sessionID: sessionID)
        else { return project.mainCodeRoot }
        let root = CodeRootPolicy.root(workbench: project, worktreeFolder: folder)
        // Also read so a worktree removed under FSEvents moves the page
        // before its place is read again.
        return codeFiles.isRemoved(root) ? project.mainCodeRoot : root
    }

    /// The session whose place sets the page's root (D6), nil without one.
    private func pageSessionID(projectID: Int64) -> Int64? {
        let focused = activeSessionID(projectID: projectID).map { [$0] } ?? []
        return CodeRootPolicy.activeSessionID(layout: layout(projectID: projectID), focusOrder: focused)
    }

    private func sessionPlaceLabel(sessionID: Int64, projectID: Int64) -> SessionPlacePresentation.PlaceLabel {
        SessionPlacePresentation.placeLabel(
            sessionPlaces.currentPlace(sessionID: sessionID), mainStatus: gitStatus[projectID],
            stale: sessionPlaces.isPlaceStale(sessionID: sessionID)
        )
    }
}
