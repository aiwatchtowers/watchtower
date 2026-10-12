import Foundation

/// Which folder a workbench page's code viewer follows (board #565, spec
/// 2026-10-12-session-worktree-design D6 and §6.1). Pure rules; the page
/// owns the inputs.
package enum CodeRootPolicy {
    /// The session whose place sets the page's root: the one the layout holds
    /// as a terminal or a Session view, in either slot — on screen or under
    /// an expanded pane. Two different sessions → the one focused last
    /// (`focusOrder` is oldest → newest), else the primary slot's. No session
    /// in the layout (the board or the Files alone) → nil, the main folder.
    package static func activeSessionID(layout: WorkspaceLayout, focusOrder: [Int64]) -> Int64? {
        var held: [Int64] = []
        for pane in [layout.primary, layout.secondary] {
            guard let id = sessionID(of: pane), !held.contains(id) else { continue }
            held.append(id)
        }
        guard held.count > 1 else { return held.first }
        return focusOrder.last(where: held.contains) ?? held.first
    }

    /// The root for the active session's place. `worktreeFolder` is the
    /// place's worktree root (`SessionPlace.worktree`'s `root`), nil for any
    /// other place — main, unknown, removed, or no session. A worktree whose
    /// directory is gone, or that names the workbench folder itself (compared
    /// symlink-resolved, so `/tmp/x` and `/private/tmp/x` match), is the main
    /// root. The returned root's own identity stays lexical (`CodeRoot.folder`).
    package static func root(
        workbench: Workbench,
        worktreeFolder: URL?,
        folderExists: (URL) -> Bool = Self.directoryExists
    ) -> CodeRoot {
        let mainRoot = workbench.mainCodeRoot
        guard let worktreeFolder, folderExists(worktreeFolder) else { return mainRoot }
        let worktreeRoot = CodeRoot(workbenchID: workbench.id, worktree: worktreeFolder)
        let sameFolder = symlinkResolvedPath(worktreeRoot.folder) == symlinkResolvedPath(mainRoot.folder)
        return sameFolder ? mainRoot : worktreeRoot
    }

    package static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The path with symlinks resolved (realpath(3)) when it exists, the
    /// standardized path otherwise. Comparison only — never a root's identity.
    private static func symlinkResolvedPath(_ url: URL) -> String {
        let standard = url.standardizedFileURL.path
        guard let resolved = realpath(standard, nil) else { return standard }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func sessionID(of pane: WorkspacePane?) -> Int64? {
        switch pane {
        case let .session(id)?, let .sessionReport(id)?: id
        default: nil
        }
    }
}
