import Foundation
import WatchtowerCore

/// One FILES root (#2003, spec §6.2): a live bench folder, the tree it
/// shows (the active session's worktree for that session's folder) and
/// what its row says.
struct FilesRootItem: Identifiable, Equatable {
    let folder: WorkbenchFolder
    /// The root its tree shows.
    let root: CodeRoot
    let name: String
    let caption: String?
    let state: WorkbenchFolderPresentation.RootState
    /// `⎇ branch ● ↑N ↓N`, nil while no readable status is known.
    let branchLine: String?
    /// The folder of the session (or root) the page works in.
    let isActive: Bool
    let isExpanded: Bool
    let isHighlighted: Bool

    var id: Int64 { folder.id }
}

/// A FILES root chosen by opening one of its files, and the page session
/// it was chosen under.
struct FilesRootSelection: Equatable {
    let root: CodeRoot
    let sessionID: Int64?
}

/// What Put on the Bench… did with the picked folder.
enum PutOnBenchStep: Equatable {
    /// The add ran (its outcome is in FILES).
    case done
    /// The folder lies under this TCC-sensitive `~/…` location: the owner
    /// confirms first (Open Folder…'s alert), then `addFolderToBench`.
    case confirmLocation(String)
}

/// The bench's folders (#2003): FILES roots, Put on the Bench…, each root's
/// git status. The Desktop never writes `workbench_folders`: every change
/// is a `workbench folder …` call (spec §7 writers).
extension WorkbenchesViewModel {
    /// The bench's folders, in position order.
    func liveFolders(projectID: Int64) -> [WorkbenchFolder] {
        benchFolders[projectID]?.live ?? []
    }

    /// A bench folder's own root: the home folder's equals the workbench's
    /// main root, so its keys and argv are today's.
    func folderRoot(_ folder: WorkbenchFolder) -> CodeRoot {
        CodeRoot(folder: folder, homeFolderID: benchFolders[folder.workbenchID]?.homeID)
    }

    /// The roots of the bench's folders other than home that are on disk:
    /// polled for their own status (spec §6.8).
    func otherFolderRoots(workbenchID: Int64) -> [CodeRoot] {
        let missing = missingFolders[workbenchID] ?? []
        return liveFolders(projectID: workbenchID)
            .filter { !missing.contains($0.id) }
            .map(folderRoot)
            .filter { $0.folderID != nil }
    }

    /// The root of a session's folder when it is not home (nil for home, a
    /// removed folder or a session the page has not read).
    func sessionFolderRoot(sessionID: Int64, project: Workbench) -> CodeRoot? {
        guard let bench = benchFolders[project.id],
              let folderID = terminalSessions[project.id]?.first(where: { $0.id == sessionID })?.workbenchFolderID,
              folderID != bench.homeID,
              let folder = bench.folder(folderID), !folder.isRemoved else { return nil }
        return folderRoot(folder)
    }

    /// A stored folder id as git calls send it (`--workbench-folder`): nil
    /// for home — and while the bench's folders are unread, when Go places
    /// the folder by its path — so the home argv stays today's.
    func nonHomeFolderID(_ folderID: Int64?, projectID: Int64) -> Int64? {
        guard let folderID, let bench = benchFolders[projectID], folderID != bench.homeID else { return nil }
        return folderID
    }

    /// The root a git key names, rebuilt for a re-read (nil: a folder no
    /// longer on the bench).
    func codeRoot(for key: GitRootKey, project: Workbench) -> CodeRoot? {
        var main = project.mainCodeRoot
        if let folderID = key.folderID {
            guard let folder = benchFolders[project.id]?.folder(folderID), !folder.isRemoved else { return nil }
            main = folderRoot(folder)
        }
        guard let worktree = key.worktreeFolder else { return main }
        return CodeRoot(workbenchID: project.id, worktree: URL(fileURLWithPath: worktree), folderID: main.folderID)
    }

    /// The list's folder rows: every workbench's at once, and which live
    /// folders are gone from disk.
    func applyBenchFolders(_ all: [Int64: BenchFolders]) {
        if benchFolders != all { benchFolders = all }
        var missing: [Int64: Set<Int64>] = [:]
        for (id, bench) in all {
            let gone = Set(bench.live.filter { !folderExists($0.folderPath) }.map(\.id))
            if !gone.isEmpty { missing[id] = gone }
        }
        if missingFolders != missing { missingFolders = missing }
    }

    /// One workbench's folder rows again (a page appeared, an add ran).
    func loadBenchFolders(projectID: Int64) async {
        do {
            let bench = try await dbPool.read { try WorkbenchFolderQueries.benchFolders($0, workbenchID: projectID) }
            var all = benchFolders
            all[projectID] = bench
            applyBenchFolders(all)
        } catch {
            print("[WorkbenchFolders] reading the folders of workbench \(projectID) failed: \(error)")
        }
    }

    /// `workbench folder list`'s install flags. A failed read keeps the
    /// last ones (the icon is a hint; Retry is always offered with it).
    func refreshFolderInstall(projectID: Int64) async {
        guard let cli else { return }
        do {
            let folders = try await cli.folderList(workbenchID: projectID)
            folderInstalled[projectID] = Dictionary(folders.map { ($0.id, $0.installed) }) { $1 }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            print("[WorkbenchFolders] workbench folder list for workbench \(projectID) failed: \(error)")
        }
    }

    /// FILES' roots in position order (§6.2). `active` is the root the page
    /// works in: its folder's row shows that tree (a session's worktree)
    /// and is always open.
    func filesRoots(project: Workbench, active: CodeRoot) -> [FilesRootItem] {
        let folders = liveFolders(projectID: project.id)
        let missing = missingFolders[project.id] ?? []
        let installed = folderInstalled[project.id] ?? [:]
        let expanded = expandedFolderRoots[project.id] ?? []
        return folders.map { folder in
            let own = folderRoot(folder)
            let isActive = own.folderID == active.folderID
            let root = isActive ? active : own
            let status = gitStatus[root]
            let label = WorkbenchFolderPresentation.rootName(folder, siblings: folders)
            let state = WorkbenchFolderPresentation.rootState(
                exists: !missing.contains(folder.id),
                gitAvailable: status?.gitAvailable ?? true,
                isRepository: status?.git ?? true,
                installed: installed[folder.id] ?? true
            )
            let branch = status.flatMap {
                WorkbenchBranchPresentation.showsButton($0) ? WorkbenchFolderPresentation.branchLine($0) : nil
            }
            return FilesRootItem(
                folder: folder, root: root, name: label.name, caption: label.caption, state: state,
                branchLine: state.trailing == nil ? branch : nil,
                isActive: isActive,
                isExpanded: state != .notFound && (isActive || expanded.contains(folder.id)),
                isHighlighted: highlightedFolderRoot[project.id] == folder.id
            )
        }
    }

    /// FILES draws a row per root with several folders, and also when a
    /// folder is gone: its row carries `Folder not found` and Locate… (a
    /// bench whose only folder moved must still reach it). One healthy
    /// folder keeps today's tree.
    static func showsRootRows(_ roots: [FilesRootItem]) -> Bool {
        roots.count > 1 || roots.contains { $0.state == .notFound }
    }

    /// Remove from Bench… on a root: off for the bench's only folder.
    func canRemoveFolder(projectID: Int64) -> Bool {
        liveFolders(projectID: projectID).count > 1
    }

    /// A root row's click: open or close its tree.
    func toggleFolderRoot(_ folderID: Int64, projectID: Int64) {
        var expanded = expandedFolderRoots[projectID] ?? []
        if expanded.remove(folderID) == nil { expanded.insert(folderID) }
        expandedFolderRoots[projectID] = expanded
    }

    /// Put on the Bench… (§6.1) after the folder panel: Open Folder…'s
    /// TCC-sensitive location asks first, unchanged; any other folder is
    /// added now.
    @discardableResult
    func putOnBench(
        _ folder: URL,
        projectID: Int64,
        home: String = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    ) async -> PutOnBenchStep {
        if let location = WorkbenchFolderPolicy.tccSensitiveLocation(path: folder.path, home: home) {
            return .confirmLocation(location)
        }
        await addFolderToBench(folder, projectID: projectID)
        return .done
    }

    /// `workbench folder add`: a new folder is highlighted and opened in
    /// FILES; `already_here` highlights the folder it already is; any other
    /// refusal (`other_bench` until the merge flow, `nested`, …) and a
    /// failed call say why under the FILES header. An install that failed
    /// leaves the folder on the bench with the install icon and Retry
    /// (spec §7 row 2); nothing is rolled back.
    func addFolderToBench(_ folder: URL, projectID: Int64) async {
        guard let cli else {
            putOnBenchErrors[projectID] = Self.cliMissingMessage
            return
        }
        guard !puttingOnBench.contains(projectID) else { return }
        puttingOnBench.insert(projectID)
        defer { puttingOnBench.remove(projectID) }
        putOnBenchErrors[projectID] = nil
        let name = folder.lastPathComponent
        let result: FolderResult
        do {
            result = try await runFolderAdd(cli, path: folder.path, projectID: projectID, addedBy: .owner)
        } catch {
            print("[WorkbenchFolders] workbench folder add for workbench \(projectID) failed: \(error)")
            putOnBenchErrors[projectID] = WorkbenchFolderPresentation.putOnBenchFailed(
                name: name, reason: error.localizedDescription)
            return
        }
        if result.ok || result.code == .alreadyHere { return }
        putOnBenchErrors[projectID] = WorkbenchFolderPresentation.putOnBenchFailed(name: name, reason: result.reason)
    }

    /// The folder card's Put on Bench (spec §6.7): the same add as the
    /// owner's, filed as the agent's suggestion. The card says how it went.
    func addSuggestedFolder(path: String, projectID: Int64) async throws -> FolderResult {
        guard let cli else { throw FolderSuggestionError.noCLI }
        return try await runFolderAdd(cli, path: path, projectID: projectID, addedBy: .agentSuggestion)
    }

    /// `workbench folder add`, then FILES again: the folder it added (or
    /// already was, `already_here`) is highlighted and opened, a new one's
    /// install flag and git status read.
    private func runFolderAdd(
        _ cli: WorkbenchCLI, path: String, projectID: Int64, addedBy: FolderAddedBy
    ) async throws -> FolderResult {
        let result = try await cli.folderAdd(workbenchID: projectID, path: path, addedBy: addedBy)
        await loadBenchFolders(projectID: projectID)
        // Added, but the CLI named no folder: nothing to highlight (and,
        // being ok, no error either).
        if result.ok || result.code == .alreadyHere, let added = result.folder {
            highlightedFolderRoot[projectID] = added.id
            expandedFolderRoots[projectID, default: []].insert(added.id)
            if result.ok { folderInstalled[projectID, default: [:]][added.id] = result.install?.ok ?? added.installed }
            if result.ok, gitWatching.contains(projectID), let added = benchFolders[projectID]?.folder(added.id) {
                await refreshGitStatus(root: folderRoot(added))
            }
        }
        return result
    }

    /// Retry on a root whose install is missing: Re-run Setup installs into
    /// every folder of the bench (`workbench resync`), then the flags again.
    func retryFolderInstall(projectID: Int64) async {
        await resync(projectID: projectID)
        await refreshFolderInstall(projectID: projectID)
    }
}
