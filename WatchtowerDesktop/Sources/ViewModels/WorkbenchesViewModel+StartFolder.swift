import Foundation
import WatchtowerCore

/// The bench folder a new session starts in (spec 2026-11-18 §6.4): the id
/// `workbench session start --folder` gets — nil for home, which sends no
/// flag, so a one-folder bench's argv stays today's — and the start notice
/// when the folder asked for left the bench.
struct StartFolder: Equatable {
    var id: Int64?
    var notice: String?

    static let home = Self()

    /// The start notice lines in order, nil when there is none.
    static func joined(_ lines: String?...) -> String? {
        let present = lines.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }
}

/// Which folder each start entry point uses (`NewSessionFolder`), the New
/// Session (+) menu's folders, and the worktree reason per folder.
extension WorkbenchesViewModel {
    /// `context`'s folder on `bench`: home (nil) while the bench's folders
    /// are unread or it has no folder row; a folder that left the bench
    /// starts in home with the notice saying so.
    func startFolder(_ context: NewSessionFolder.Context, bench: BenchFolders?) -> StartFolder {
        guard let bench, let home = bench.homeID else { return .home }
        let wanted = NewSessionFolder.folderID(for: context, homeFolderID: home)
        let resolved = NewSessionFolder.resolve(wanted, folders: bench)
        return StartFolder(id: resolved.folderID == home ? nil : resolved.folderID, notice: resolved.notice)
    }

    /// ⌘T's context (and the plain New Session click's): the session on
    /// screen, else the FILES root the owner last opened.
    func shortcutFolder(projectID: Int64) -> NewSessionFolder.Context {
        let session = pageSessionID(projectID: projectID).flatMap { id in
            terminalSessions[projectID]?.first { $0.id == id }
        }
        let root = selectedFolderRoot[projectID].flatMap { benchFolders[projectID]?.folder($0) }
            .flatMap { $0.isRemoved ? nil : folderRoot($0) }
        return .shortcut(currentSession: session, selectedRoot: root)
    }

    /// The New Session (+) menu's folders for the page's context.
    func newSessionMenu(projectID: Int64) -> SessionNestingPresentation.NewSessionMenu? {
        guard let bench = benchFolders[projectID], let home = bench.homeID else { return nil }
        let context = NewSessionFolder.folderID(for: shortcutFolder(projectID: projectID), homeFolderID: home)
        return SessionNestingPresentation.newSessionMenu(folders: bench, contextFolderID: context)
    }

    // MARK: - Sub-sessions on the strip (§6.5)

    /// The session that started `sessionID` as its sub-session, when the
    /// page lists it (nil for a top-level session or a parent gone).
    func parentSession(of sessionID: Int64, projectID: Int64) -> TerminalSession? {
        let rows = terminalSessions[projectID] ?? []
        guard let parent = rows.first(where: { $0.id == sessionID })?.parentSessionID else { return nil }
        return rows.first { $0.id == parent }
    }

    /// The session's folder name on a bench of several folders; nil on a
    /// one-folder bench (its strip looks as it did).
    func sessionFolderName(sessionID: Int64, projectID: Int64) -> String? {
        guard let session = terminalSessions[projectID]?.first(where: { $0.id == sessionID }) else { return nil }
        return SessionNestingPresentation.folderLabel(folderID: session.workbenchFolderID, folders: benchFolders[projectID])
    }

    /// `📁 hub › ⑂ export-api › ⎇ wt/export-api ●` for the session's strip.
    func stripTrail(sessionID: Int64, project: Workbench, folder: String) -> String {
        switch sessionPlaces.currentPlace(sessionID: sessionID) {
        case let .worktree(name, _, status):
            return SessionNestingPresentation.stripTrail(
                folder: folder, worktree: name, branch: status.branch.isEmpty ? nil : status.branch, dirty: status.dirty
            )
        case .unknown, .main, .removed:
            let status = sessionFolderRoot(sessionID: sessionID, project: project).flatMap { gitStatus[$0] }
            return SessionNestingPresentation.stripTrail(
                folder: folder, worktree: nil, branch: status.flatMap { $0.branch.isEmpty ? nil : $0.branch },
                dirty: status?.dirty ?? false
            )
        }
    }

    // MARK: - An agent message in the prompt (§6.6)

    /// The prompt notice offers Dismiss: the session host is known to lack
    /// `PromptState`, so nothing else clears the flag before the run ends.
    var promptNoticeOffersDismiss: Bool {
        SessionNestingPresentation.offersDismiss(
            hostHasPromptState: !(terminalCenter?.sessionHost?.lacksPromptState ?? false)
        )
    }

    /// Dismiss: every message flagged in the session's prompt is marked
    /// cleared through `workbench message dismiss --id` (the Desktop never
    /// writes `session_messages`), then the states are read again. A failure
    /// keeps the flag and says so on the page.
    func dismissPromptMessages(sessionID: Int64, projectID: Int64) async {
        guard let cli else { return }
        do {
            let ids = try await dbPool.read { try SessionMessageQueries.waitingInPromptIDs($0, sessionID: sessionID) }
            for id in ids {
                let ack = try await cli.messageDismiss(id: id)
                if !ack.ok { throw WorkbenchCLIError.refused(ack.error.isEmpty ? ack.errorCode : ack.error) }
            }
        } catch {
            setSessionError("Could not dismiss the agent message: \(error.localizedDescription)", projectID: projectID)
        }
        agentStates?.refresh()
    }

    /// Why "In Its Own Worktree" is disabled for a start in `folderID` (nil
    /// or home: the workbench's own status), from that folder's last git
    /// status (no new read); nil when one can be made or none was read yet.
    func worktreeUnavailableReason(projectID: Int64, folderID: Int64?) -> String? {
        guard let folderID = nonHomeFolderID(folderID, projectID: projectID),
              let folder = benchFolders[projectID]?.folder(folderID) else {
            return worktreeUnavailableReason(projectID: projectID)
        }
        return gitStatus[folderRoot(folder)].flatMap(SessionStartPlacement.unavailableReason)
    }
}
