import Foundation
import WatchtowerCore

/// The branch popover's `git fetch origin` (board #563): a background fetch
/// when the popover opens and the last try is over five minutes old, and the
/// Fetch button. Go runs the fetch (`workbench git fetch`) and never lets it
/// prompt; a failure is a quiet note and the list keeps working on the local
/// refs. One fetch at a time per repository, held here so it outlives the
/// popover.
extension WorkbenchesViewModel {
    /// The repository `key` works on — its common dir, shared by its
    /// worktrees — once a status placed it; nil before (no fetch then).
    func gitFetchRepository(_ key: GitRootKey) -> String? {
        guard gitRootIsPlaced(key), let status = gitStatus[key], status.git, !status.commonDir.isEmpty else { return nil }
        return TerminalCenter.resolvedPath(status.commonDir)
    }

    /// The fetch row's state for `key`'s repository.
    func gitFetchState(_ key: GitRootKey) -> GitFetchState? {
        gitFetchRepository(key).flatMap { gitFetchStates[$0] }
    }

    /// The popover opened: fetch in the background when it is due
    /// (`WorkbenchFetchPresentation.isBackgroundFetchDue`).
    func fetchOriginIfDue(project: Workbench, root: CodeRoot? = nil) {
        let root = root ?? activeCodeRoot(project: project)
        guard let repo = gitFetchRepository(GitRootKey(root)),
              WorkbenchFetchPresentation.isBackgroundFetchDue(gitFetchStates[repo], now: gitFetchNow()) else { return }
        startFetch(project: project, root: root, repository: repo)
    }

    /// The Fetch button: fetch now unless one is running.
    func fetchOrigin(project: Workbench, root: CodeRoot? = nil) {
        let root = root ?? activeCodeRoot(project: project)
        guard let repo = gitFetchRepository(GitRootKey(root)) else { return }
        startFetch(project: project, root: root, repository: repo)
    }

    // MARK: - Private

    private func startFetch(project: Workbench, root: CodeRoot, repository repo: String) {
        guard let cli, gitFetchStates[repo]?.running != true else { return }
        var state = gitFetchStates[repo] ?? GitFetchState()
        state.running = true
        state.lastAttemptAt = gitFetchNow()
        gitFetchStates[repo] = state
        let key = GitRootKey(root)
        gitFetchTasks[repo] = Task { [weak self] in
            let outcome: Result<WorkbenchGitFetchResult, Error>
            do {
                outcome = .success(try await cli.gitFetch(projectID: project.id, folder: key.worktreeFolder))
            } catch {
                outcome = .failure(error)
            }
            await self?.finishFetch(outcome, project: project, root: root, repository: repo)
        }
    }

    private func finishFetch(
        _ outcome: Result<WorkbenchGitFetchResult, Error>, project: Workbench, root: CodeRoot, repository repo: String
    ) async {
        defer { gitFetchTasks[repo] = nil }
        var state = gitFetchStates[repo] ?? GitFetchState()
        state.running = false
        switch outcome {
        case let .success(result):
            state.noRemote = result.noRemote
            state.failure = WorkbenchFetchPresentation.failure(result)
            if result.fetched { state.lastFetchedAt = gitFetchNow() } // the app's clock, as the rarity's
        case let .failure(error):
            print("[WorkbenchGit] workbench git fetch for workbench \(project.id) failed: \(error)")
            state.failure = WorkbenchFetchPresentation.failure(
                callError: WorkbenchBranchPresentation.failureText(error, command: "fetch"))
        }
        gitFetchStates[repo] = state
        guard case let .success(result) = outcome, result.fetched else { return }
        // Only origin's refs moved: the counters and the remote-only list of
        // the workbench's roots on this repository read so far (its main
        // folder and a session's worktree share them).
        var roots = [root]
        for key in gitStatus.keys
        where key.workbenchID == project.id && key != GitRootKey(root) && gitFetchRepository(key) == repo {
            roots.append(key.worktreeFolder.map { CodeRoot(workbenchID: project.id, worktree: URL(fileURLWithPath: $0)) }
                ?? project.mainCodeRoot)
        }
        for other in roots {
            await refreshGitStatus(root: other)
            if other == root || gitBranches[other] != nil { await reloadBranchList(project: project, root: other) }
        }
    }
}
