import Foundation
import WatchtowerCore

extension WorkbenchesViewModel {
    /// The folder a reviewed session works in (#2003), for the reviewer's
    /// thread key: `.home` for the home folder (or a row without a folder),
    /// else that folder with its own git status read now (nil when the read
    /// failed or Go resolved another folder). nil when the folders cannot be read: no thread opens rather
    /// than home's.
    func reviewedFolder(sessionID: Int64, projectID: Int64) async -> ReviewerSurface.ReviewedFolder? {
        guard let folderID = session(sessionID, projectID: projectID)?.workbenchFolderID else { return .home }
        let folders: BenchFolders
        do {
            folders = try await dbPool.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: projectID) }
        } catch {
            return nil
        }
        if folderID == folders.homeID { return .home }
        guard let folder = folders.folder(folderID), let cli else { return .other(nil) }
        // `--workbench-folder` (Task 4): Go reads that folder's own
        // repository. A status Go resolved against another folder (an older
        // CLI answers home's) keys nothing.
        guard let status = try? await cli.gitStatus(projectID: projectID, folderID: folder.id),
              Self.resolved(status, in: folder) else { return .other(nil) }
        return .other(status)
    }

    /// Whether Go read `status` in `folder` (`workbench_folder_path`, any
    /// spelling of it).
    static func resolved(_ status: WorkbenchGitStatus, in folder: WorkbenchFolder) -> Bool {
        !status.workbenchFolderPath.isEmpty
            && comparableFolder(status.workbenchFolderPath).caseInsensitiveCompare(comparableFolder(folder.folderPath)) == .orderedSame
    }
}
