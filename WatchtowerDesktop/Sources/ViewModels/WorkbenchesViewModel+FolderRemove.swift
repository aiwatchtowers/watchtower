import Foundation
import WatchtowerCore

/// Remove from Bench… and Locate… on a FILES root (#2003, spec §6.3). The
/// Desktop never writes `workbench_folders`: both are `workbench folder …`
/// calls, and Go re-checks every rule inside its transaction (spec §7 row 4).
extension WorkbenchesViewModel {
    /// What Remove from Bench… shows first: a refusal (the bench's last
    /// folder, or sessions running in it), else the confirmation.
    func removeDialog(_ folder: WorkbenchFolder) -> WorkbenchFolderPresentation.RemoveDialog {
        if liveFolders(projectID: folder.workbenchID).count(where: { $0.id != folder.id }) == 0 {
            return WorkbenchFolderPresentation.removeRefusedLast(name: folder.name)
        }
        let running = runningSessions(in: folder)
        if running > 0 { return WorkbenchFolderPresentation.removeRefusedSessions(name: folder.name, count: running) }
        return WorkbenchFolderPresentation.removeConfirm(name: folder.name)
    }

    /// The agent sessions running now in `folder` — its own rows, and for
    /// the home folder the rows with no folder (Go's `SessionRowsSQL`).
    func runningSessions(in folder: WorkbenchFolder) -> Int {
        let live = liveSessionIDs()
        let isHome = benchFolders[folder.workbenchID]?.homeID == folder.id
        return (terminalSessions[folder.workbenchID] ?? []).count { session in
            guard session.kind != .shell, live.contains(session.id) else { return false }
            guard let folderID = session.workbenchFolderID else { return isHome }
            return folderID == folder.id
        }
    }

    /// Remove after the confirmation: `workbench folder remove`, then the
    /// list again (the home folder may have moved). Go's refusal — a session
    /// started meanwhile, or the other folders went — comes back as the
    /// dialog to show; any other failure is a line under the FILES header.
    func removeFromBench(_ folder: WorkbenchFolder) async -> WorkbenchFolderPresentation.RemoveDialog? {
        let projectID = folder.workbenchID
        guard let cli else {
            putOnBenchErrors[projectID] = Self.cliMissingMessage
            return nil
        }
        putOnBenchErrors[projectID] = nil
        let result: FolderResult
        do {
            result = try await cli.folderRemove(workbenchID: projectID, folderID: folder.id)
        } catch {
            print("[WorkbenchFolders] workbench folder remove of folder \(folder.id) failed: \(error)")
            putOnBenchErrors[projectID] = WorkbenchFolderPresentation.removeFailed(
                name: folder.name, reason: error.localizedDescription)
            return nil
        }
        switch result.code {
        case .sessionsRunning, .lastFolder:
            return WorkbenchFolderPresentation.removeRefused(name: folder.name, reason: result.reason)
        default:
            break
        }
        await reload() // the list and every bench's folders (the home may have moved)
        if !result.ok {
            putOnBenchErrors[projectID] = WorkbenchFolderPresentation.removeFailed(name: folder.name, reason: result.reason)
        } else if let install = result.install, !install.ok {
            // The folder is off the bench; its install stayed (logged, said).
            print("[WorkbenchFolders] uninstalling from \(folder.folderPath) failed: \(install.error)")
            putOnBenchErrors[projectID] = WorkbenchFolderPresentation.removeFailed(name: folder.name, reason: install.error)
        }
        if highlightedFolderRoot[projectID] == folder.id { highlightedFolderRoot[projectID] = nil }
        return nil
    }

    /// Locate… after the folder panel: Open Folder…'s TCC-sensitive location
    /// asks first, unchanged; any other place is located now.
    @discardableResult
    func locate(
        _ folder: WorkbenchFolder,
        to url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    ) async -> PutOnBenchStep {
        if let location = WorkbenchFolderPolicy.tccSensitiveLocation(path: url.path, home: home) {
            return .confirmLocation(location)
        }
        await locateFolder(folder, to: url)
        return .done
    }

    /// `workbench folder locate` re-points
    /// the missing folder (Go validates the path as an add) and reinstalls
    /// there; then FILES again. A refusal or failure is a line under the
    /// FILES header; a failed reinstall leaves the install icon and Retry.
    func locateFolder(_ folder: WorkbenchFolder, to url: URL) async {
        let projectID = folder.workbenchID
        guard let cli else {
            putOnBenchErrors[projectID] = Self.cliMissingMessage
            return
        }
        putOnBenchErrors[projectID] = nil
        let result: FolderResult
        do {
            result = try await cli.folderLocate(workbenchID: projectID, folderID: folder.id, to: url.path)
        } catch {
            print("[WorkbenchFolders] workbench folder locate of folder \(folder.id) failed: \(error)")
            putOnBenchErrors[projectID] = WorkbenchFolderPresentation.locateFailed(
                name: folder.name, reason: error.localizedDescription)
            return
        }
        guard result.ok else {
            putOnBenchErrors[projectID] = WorkbenchFolderPresentation.locateFailed(name: folder.name, reason: result.reason)
            return
        }
        await reload() // the list and every bench's folders (the home may have moved)
        let located = result.folder?.id ?? folder.id
        folderInstalled[projectID, default: [:]][located] = result.install?.ok ?? result.folder?.installed ?? true
        if gitWatching.contains(projectID), let moved = benchFolders[projectID]?.folder(located) {
            await refreshGitStatus(root: folderRoot(moved))
        }
    }
}
