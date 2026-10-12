import AppKit
import Foundation
import WatchtowerCore

/// The header's branch button and popover (#233). Every git operation is a
/// `watchtower workbench git` call — Go owns git and every switch guard; the
/// Desktop only supplies the one fact Go cannot know (a live Claude Code
/// session it runs in the folder), saves the code viewer's edits before a
/// switch, and resends what the owner confirmed.
/// Never a force, a discard or an automatic stash pop. Since board #565 it
/// works on the root the page shows (`activeCodeRoot`): a session's
/// worktree goes through `--folder`, the main folder's argv is unchanged.
extension WorkbenchesViewModel {
    /// How often the page on screen re-reads the status for the dirty dot
    /// (edits do not touch refs, so the watcher misses them).
    static let gitPollInterval: Duration = .seconds(15)

    static let cliMissingMessage = "The watchtower CLI was not found."

    enum BranchListState: Equatable {
        case loading
        case loaded
        /// The owner's line: why the list could not be read.
        case failed(String)
    }

    /// Reads `workbench git status` of the main folder.
    func refreshGitStatus(projectID: Int64) async {
        await refreshGitStatus(key: .mainFolder(projectID))
    }

    /// Reads `workbench git status` of `root` — with `--folder` for a
    /// worktree root (board #565), without for the main folder.
    func refreshGitStatus(root: CodeRoot) async {
        await refreshGitStatus(key: GitRootKey(root))
    }

    /// Reads `workbench git status`. Coalesced: a call while one runs only
    /// asks for one more read after it, so a burst of FSEvents, the poll
    /// and an app activation cost at most two CLI calls. A cancelled read
    /// keeps the last status and reports nothing; a failed one (the call,
    /// or git inside the repository) keeps it too and says why.
    private func refreshGitStatus(key: GitRootKey) async {
        guard let cli else {
            gitStatusErrors[key] = Self.cliMissingMessage
            return
        }
        guard !gitRefreshing.contains(key) else {
            gitRefreshQueued.insert(key)
            return
        }
        gitRefreshing.insert(key)
        defer { gitRefreshing.remove(key) }
        repeat {
            gitRefreshQueued.remove(key)
            do {
                let status = try await cli.gitStatus(projectID: key.workbenchID, folder: key.worktreeFolder)
                applyGitStatus(status, key: key)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    // Another caller's rerun is not this task's to drop: it
                    // runs once this loop has let go of the key.
                    if gitRefreshQueued.contains(key) {
                        Task { await self.refreshGitStatus(key: key) }
                    }
                    return
                }
                // The last known status stays, so the button does not vanish.
                gitStatusErrors[key] = "Could not read the git status: "
                    + gitFailureText(error, command: "status", workbenchID: key.workbenchID)
            }
        } while gitRefreshQueued.contains(key)
    }

    /// The popover opened: the branch list (CLI) and the board's branch
    /// targets (DB) for the badges. Clears the previous popover's messages,
    /// but not the stash note. `root` defaults to the one the page shows.
    func loadBranches(project: Workbench, root: CodeRoot? = nil) async {
        let root = root ?? activeCodeRoot(project: project)
        gitErrors[root] = nil
        gitNotices[root] = nil
        await reloadBranchList(project: project, root: root)
    }

    /// Starts a switch. The first call never carries a confirmation flag:
    /// Go answers `needs_confirmation` for a dirty tree or a live agent, and
    /// the switch waits in `pendingBranchConfirmation` for the owner.
    func switchBranch(_ branch: String, project: Workbench, root: CodeRoot? = nil) async {
        let root = root ?? activeCodeRoot(project: project)
        guard switchingBranch[root] == nil else { return }
        pendingBranchConfirmation[root] = nil
        await runSwitch(branch, project: project, root: root, stash: false, confirmAgent: false)
    }

    /// The owner confirmed a switch: resend it with exactly the flags the
    /// dialog named, in the root it was asked in. The live-session fact is
    /// read again, so an agent started since the first try is still asked
    /// about. The dialog passes the confirmation it showed: dismissing it
    /// clears the pending one, possibly before this runs.
    func confirmPendingSwitch(
        project: Workbench, confirming confirmation: BranchSwitchConfirmation, root: CodeRoot? = nil
    ) async {
        let root = root ?? activeCodeRoot(project: project)
        guard switchingBranch[root] == nil else { return }
        pendingBranchConfirmation[root] = nil
        await runSwitch(confirmation.branch, project: project, root: root,
                        stash: confirmation.stash, confirmAgent: confirmation.confirmAgent)
    }

    func cancelPendingSwitch(projectID: Int64) {
        cancelPendingSwitch(key: .mainFolder(projectID))
    }

    func cancelPendingSwitch(key: GitRootKey) {
        pendingBranchConfirmation[key] = nil
    }

    /// The owner read the stash note: the entry itself stays on the stack.
    func dismissStashNote(projectID: Int64) {
        dismissStashNote(key: .mainFolder(projectID))
    }

    func dismissStashNote(key: GitRootKey) {
        gitStashNotes[key] = nil
    }

    /// "New branch from current…": `git switch -c` from HEAD (no files
    /// change, so no guard and no save of the code viewer's edits first).
    /// Returns whether the branch was created.
    @discardableResult
    func createBranch(_ name: String, project: Workbench, root: CodeRoot? = nil) async -> Bool {
        let root = root ?? activeCodeRoot(project: project)
        let key = GitRootKey(root)
        guard switchingBranch[key] == nil else { return false }
        guard let cli else {
            gitErrors[key] = Self.cliMissingMessage
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            gitErrors[key] = "Enter a name for the new branch."
            return false
        }
        gitErrors[key] = nil
        gitNotices[key] = nil
        switchingBranch[key] = trimmed
        defer { switchingBranch[key] = nil }
        let result: WorkbenchGitSwitchResult
        do {
            result = try await cli.gitCreateBranch(projectID: project.id, name: trimmed, folder: key.worktreeFolder)
        } catch {
            gitErrors[key] = "Could not create \(trimmed): "
                + gitFailureText(error, command: "create", workbenchID: project.id)
            // The call may have failed after git wrote.
            await refreshGitStatus(key: key)
            return false
        }
        let created = result.created || result.switched
        let outcome = WorkbenchBranchPresentation.outcome(result)
        gitErrors[key] = outcome.error ?? (created ? nil : "The branch was not created.")
        gitNotices[key] = outcome.notice
        if let stash = outcome.stash { gitStashNotes[key] = stash }
        await afterGitWrite(project: project, root: root)
        return created
    }

    /// "Copy branch name": the branch, or the hash on a detached HEAD.
    func copyBranchName(projectID: Int64) {
        copyBranchName(key: .mainFolder(projectID))
    }

    func copyBranchName(key: GitRootKey) {
        guard let status = gitStatus[key] else { return }
        let text = WorkbenchBranchPresentation.label(status).text
        guard !text.isEmpty else { return }
        copyToPasteboard(text)
    }

    /// The page is on screen: read the status, then follow it — the refs
    /// watcher, app activation and the dirty-dot poll (only while the tab is
    /// what the owner sees). The sessions' places follow the same page
    /// (board #565); their reads are not this task's, so leaving the page
    /// does not cancel them. The worktree the page shows is followed too
    /// (`followGitRoot`).
    func startGitWatching(project: Workbench) async {
        let id = project.id
        gitWatching.insert(id)
        sessionPlaces.followWorkbench(id, folder: project.folderPath)
        observeAppActivation()
        if gitTimers[id] == nil {
            gitTimers[id] = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.gitPollSleep(Self.gitPollInterval)
                    guard !Task.isCancelled, let self else { return }
                    if self.isTabOnScreen() { await self.refreshWatchedRoots(workbenchID: id) }
                }
            }
        }
        await refreshGitStatus(projectID: id)
        // The read above arms the watcher; a status already known (a read
        // coalesced into one in flight) arms it now.
        if let status = gitStatus[id] { armGitWatcher(status, key: .mainFolder(id)) }
        await followGitRoot(activeCodeRoot(project: project))
    }

    /// The page's branch menu moved to `root` (board #565): a worktree root
    /// is read and watched beside the main folder — its status, its refs
    /// watcher, the poll and app activation — until the page shows another
    /// root or goes away. The main root is always watched by the page.
    func followGitRoot(_ root: CodeRoot) async {
        let id = root.workbenchID
        guard gitWatching.contains(id) else { return }
        let next: CodeRoot? = root.isMain ? nil : root
        guard gitWatchedWorktree[id] != next else { return }
        if let old = gitWatchedWorktree.removeValue(forKey: id) { stopGitWatcher(key: GitRootKey(old)) }
        guard let next else { return }
        gitWatchedWorktree[id] = next
        await refreshGitStatus(root: next)
        if let status = gitStatus[next] { armGitWatcher(status, key: GitRootKey(next)) }
    }

    /// The page went away: stop watching. The last status, a switch in
    /// flight and its pending confirmation all stay.
    func stopGitWatching(projectID: Int64) {
        gitWatching.remove(projectID)
        sessionPlaces.unfollowWorkbench(projectID)
        gitTimers.removeValue(forKey: projectID)?.cancel()
        stopGitWatcher(key: .mainFolder(projectID))
        if let worktree = gitWatchedWorktree.removeValue(forKey: projectID) {
            stopGitWatcher(key: GitRootKey(worktree))
        }
        if gitWatching.isEmpty, let observer = gitActivationObserver {
            gitNotificationCenter.removeObserver(observer)
            gitActivationObserver = nil
        }
    }

    /// Where a session's agent may work, for the branch switch's agent
    /// check (spec §5.3): its place, but a stale one (a read pending or
    /// failed) is unknown — maybe in the worktree being switched.
    func agentPlace(sessionID: Int64) -> SessionPlace {
        sessionPlaces.isPlaceStale(sessionID: sessionID) ? .unknown : sessionPlaces.currentPlace(sessionID: sessionID)
    }

    // MARK: - Private

    private func runSwitch(_ branch: String, project: Workbench, root: CodeRoot, stash: Bool, confirmAgent: Bool) async {
        let id = project.id
        let key = GitRootKey(root)
        guard let cli else {
            gitErrors[key] = Self.cliMissingMessage
            return
        }
        gitErrors[key] = nil
        gitNotices[key] = nil
        switchingBranch[key] = branch
        defer { switchingBranch[key] = nil }
        // The switch swaps the whole work tree of that root, not just the
        // folder: a session at the repository root or in a sibling counts.
        let topLevel = gitStatus[key]?.topLevel ?? ""
        let workTree = topLevel.isEmpty ? (key.worktreeFolder ?? project.folderPath) : topLevel
        guard await saveBeforeSwitch(root: root, workTree: workTree) else { return }
        let agentRunning = terminalCenter?.hasLiveAgentSession(workbenchID: id, workTree: workTree) { [weak self] in
            self?.agentPlace(sessionID: $0) ?? .unknown
        } ?? false
        let result: WorkbenchGitSwitchResult
        do {
            result = try await cli.gitSwitch(projectID: id, branch: branch, stash: stash, agentRunning: agentRunning,
                                             confirmAgent: confirmAgent && agentRunning, folder: key.worktreeFolder)
        } catch {
            gitErrors[key] = "Could not switch to \(branch): \(gitFailureText(error, command: "switch", workbenchID: id))"
            await refreshGitStatus(key: key)
            return
        }
        // Go wrote nothing: wait for the owner, no further call. A stash
        // the owner already agreed to rides along with what Go asks now.
        if let confirmation = WorkbenchBranchPresentation.confirmation(for: result, stashing: stash) {
            pendingBranchConfirmation[key] = confirmation
            pendingBranchBase[key] = gitStatus[key].map { WorkbenchBranchPresentation.label($0).text }
            return
        }
        let outcome = WorkbenchBranchPresentation.outcome(result)
        let moved = result.switched || result.already
        gitErrors[key] = outcome.error ?? (moved ? nil : "Not switched to \(branch).")
        gitNotices[key] = outcome.notice
        if let stash = outcome.stash { gitStashNotes[key] = stash }
        await afterGitWrite(project: project, root: root)
    }

    /// Edits typed in the code viewer are not on disk until their autosave:
    /// those of the switched root (and of any workbench root inside its work
    /// tree) are saved now, so Go's dirty check sees them (and a stash takes
    /// them). Another worktree's or the main folder's are not this switch's.
    /// One that cannot be written, or a page that does not hand its edits
    /// over, would leave them under the other branch — nothing is sent.
    private func saveBeforeSwitch(root: CodeRoot, workTree: String) async -> Bool {
        let key = GitRootKey(root)
        switch await codeFiles.saveEdits(root: root, workTree: workTree) {
        case .saved:
            return true
        case let .unsaved(path):
            gitErrors[key] = "Save or discard the edits in \(path) first — they are not on disk yet."
        case .editorSilent:
            gitErrors[key] = "The editor did not hand over its latest edits — try again."
        }
        return false
    }

    /// After a switch or create, whatever its outcome (a failed switch may
    /// have restored a stash): a fresh status read — not the envelope's,
    /// which a refusal may leave empty — and the branch list again.
    private func afterGitWrite(project: Workbench, root: CodeRoot) async {
        await refreshGitStatus(root: root)
        await reloadBranchList(project: project, root: root)
    }

    /// The branch list, then the board's branch targets for the badges. A
    /// failed list keeps the last good one (shown as stale); a failed
    /// badge read drops the old badges rather than show them as current.
    private func reloadBranchList(project: Workbench, root: CodeRoot) async {
        let id = project.id
        let key = GitRootKey(root)
        guard let cli else {
            branchListStates[key] = .failed(Self.cliMissingMessage)
            return
        }
        branchListStates[key] = .loading
        do {
            let list = try await cli.gitBranches(projectID: id, folder: key.worktreeFolder)
            if list.branchesOK, list.refused.isEmpty {
                gitBranches[key] = list
                branchListStates[key] = .loaded
            } else {
                branchListStates[key] = .failed(Self.branchListFailure(list))
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                // The popover closed; the next one reads again.
                branchListStates[key] = nil
                return
            }
            let detail = gitFailureText(error, command: "branches", workbenchID: id)
            branchListStates[key] = .failed(Self.branchListFailure(detail))
        }
        do {
            branchTargets[key] = try await dbPool.read { try WorkbenchQueries.branchTargets($0, projectID: id) }
        } catch {
            branchTargets[key] = nil
            print("[WorkbenchGit] board branch targets for workbench \(id) failed: \(error)")
            let problem = "Could not read the board's branches: \(error.localizedDescription)"
            gitErrors[key] = [gitErrors[key], problem].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// A refused folder (board #565) says why in the owner's words; a failed
    /// listing says git's error or the note.
    private static func branchListFailure(_ list: WorkbenchGitBranches) -> String {
        if !list.refused.isEmpty {
            return WorkbenchBranchPresentation.refusalText(refused: list.refused, detail: list.refusedDetail)
        }
        return branchListFailure(list.branchesError.isEmpty ? list.note : list.branchesError)
    }

    private static func branchListFailure(_ detail: String) -> String {
        detail.isEmpty ? "Could not list branches." : "Could not list branches: \(detail)"
    }

    /// A status git could not read inside the repository is a failed read:
    /// the last good status stays and the error says why. A worktree root
    /// Go no longer places in a worktree gets the main folder's status and
    /// says so until the session's place falls back.
    private func applyGitStatus(_ status: WorkbenchGitStatus, key: GitRootKey) {
        if status.git, !status.statusOK {
            gitStatusErrors[key] = "Could not read the git status: \(status.statusError)"
            return
        }
        gitStatus[key] = status
        gitStatusErrors[key] = key.worktreeFolder == nil ? nil : WorkbenchBranchPresentation.worktreeScopeNote(status)
        dropOutdatedConfirmation(status, key: key)
        armGitWatcher(status, key: key)
    }

    /// A pending question about a branch the folder is already on, or asked
    /// from a branch it has since left, no longer describes the switch.
    private func dropOutdatedConfirmation(_ status: WorkbenchGitStatus, key: GitRootKey) {
        guard let pending = pendingBranchConfirmation[key] else { return }
        let now = WorkbenchBranchPresentation.label(status).text
        let moved = pendingBranchBase[key].map { $0 != now } ?? false
        if now == pending.branch || moved {
            pendingBranchConfirmation[key] = nil
        }
    }

    /// Whether a page watches `key`: its main folder, or the worktree its
    /// branch menu works on.
    private func isGitWatched(_ key: GitRootKey) -> Bool {
        guard gitWatching.contains(key.workbenchID) else { return false }
        guard key.worktreeFolder != nil else { return true }
        return gitWatchedWorktree[key.workbenchID].map(GitRootKey.init) == key
    }

    /// (Re)creates the refs watcher when the root is watched and the dirs
    /// changed (a worktree moved, `.git` appeared); none outside a repository.
    private func armGitWatcher(_ status: WorkbenchGitStatus, key: GitRootKey) {
        guard isGitWatched(key) else { return }
        let dirs = status.git && !status.gitDir.isEmpty ? [status.gitDir, status.commonDir] : []
        guard dirs != gitWatchedDirs[key] else { return }
        gitWatchers.removeValue(forKey: key)?.stop()
        gitWatchedDirs[key] = dirs
        guard !dirs.isEmpty else { return }
        let id = key.workbenchID
        let isMain = key.worktreeFolder == nil
        // The common dir holds every worktree's HEAD and the refs: a
        // worktree session's branch is read again too, unless only the
        // folder's own HEAD or index moved (board #565).
        gitWatchers[key] = makeGitWatcher(status.gitDir, status.commonDir) { [weak self] change in
            if isMain, change.mayMoveWorktrees { self?.sessionPlaces.refreshPlaces(workbenchID: id) }
            Task { await self?.refreshGitStatus(key: key) }
        }
    }

    private func stopGitWatcher(key: GitRootKey) {
        gitWatchers.removeValue(forKey: key)?.stop()
        gitWatchedDirs[key] = nil
    }

    /// The poll and app activation: the main folder and the worktree the
    /// page's branch menu works on.
    private func refreshWatchedRoots(workbenchID id: Int64) async {
        await refreshGitStatus(projectID: id)
        if let worktree = gitWatchedWorktree[id] { await refreshGitStatus(root: worktree) }
    }

    /// The owner's line for a failed call; the raw error goes to the log.
    private func gitFailureText(_ error: Error, command: String, workbenchID: Int64) -> String {
        print("[WorkbenchGit] workbench git \(command) for workbench \(workbenchID) failed: \(error)")
        return WorkbenchBranchPresentation.failureText(error, command: command)
    }

    private func observeAppActivation() {
        guard gitActivationObserver == nil else { return }
        gitActivationObserver = gitNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in self.gitWatching {
                    self.sessionPlaces.refreshPlaces(workbenchID: id)
                    Task { await self.refreshWatchedRoots(workbenchID: id) }
                }
            }
        }
    }
}
