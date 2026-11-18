import Foundation

/// The bench folder a new session starts in (spec 2026-11-18 §6.4): every
/// start entry point — the New Session (+) items, ⌘T, Work on It, a FILES
/// root's New Session Here, drift Fix — asks this, none picks a folder on
/// its own. A stored folder id of nil is the home folder.
package enum NewSessionFolder {
    package enum Context: Sendable {
        /// ⌘T (and the plain New Session click): the session on screen's
        /// folder, else the FILES root the owner opened, else home.
        case shortcut(currentSession: TerminalSession?, selectedRoot: CodeRoot?)
        /// Work on It: the target's folder, home when it names none.
        case workOnIt(target: Target)
        /// A FILES root's New Session Here: that root's folder.
        case filesRoot(CodeRoot)
        /// A New Session (+) item: its folder.
        case menu(folderID: Int64)
    }

    package static func folderID(for context: Context, homeFolderID: Int64) -> Int64 {
        switch context {
        case let .shortcut(session, root):
            if let session { return session.workbenchFolderID ?? homeFolderID }
            return root.map { $0.folderID ?? homeFolderID } ?? homeFolderID
        case let .workOnIt(target):
            return target.workbenchFolderID ?? homeFolderID
        case let .filesRoot(root):
            return root.folderID ?? homeFolderID
        case let .menu(folderID):
            return folderID
        }
    }

    /// Where a start in `folderID` really goes on `folders`: that folder
    /// while it is on the bench; home, with the start notice naming it, when
    /// it left the bench (a target's folder removed, spec §6.3) or this bench
    /// does not hold it.
    package static func resolve(
        _ folderID: Int64, folders: BenchFolders
    ) -> (folderID: Int64, notice: String?) {
        guard let home = folders.home, folderID != home.id else { return (folderID, nil) }
        guard let folder = folders.folder(folderID) else { return (home.id, nil) }
        guard folder.isRemoved else { return (folderID, nil) }
        return (home.id, SessionStartPlacementPresentation.folderLeftTheBench(home: home.name, folder: folder.name))
    }
}
