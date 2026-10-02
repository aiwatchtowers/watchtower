import AppKit
import Foundation
import WatchtowerCore

/// The header's branch button and popover (#233). Every git operation is a
/// `watchtower workbench git` call — Go owns git and every switch guard; the
/// Desktop only supplies the one fact Go cannot know (a live Claude Code
/// session it runs in the folder) and resends what the owner confirmed.
/// Never a force, a discard or an automatic stash pop.
extension WorkbenchesViewModel {
    /// How often the page on screen re-reads the status for the dirty dot
    /// (edits do not touch refs, so the watcher misses them).
    static let gitPollInterval: Duration = .seconds(15)

    static let cliMissingMessage = "The watchtower CLI was not found."

    /// Whether the header shows `›` and the branch button.
    func showsBranchButton(projectID: Int64) -> Bool {
        WorkbenchBranchPresentation.showsButton(gitStatus[projectID])
    }

    /// Reads `workbench git status`. Coalesced: a call while one runs only
    /// asks for one more read after it, so a burst of FSEvents, the poll
    /// and an app activation cost at most two CLI calls. A cancelled read
    /// keeps the last status and reports nothing; a failed one (the call,
    /// or git inside the repository) keeps it too and says why.
    func refreshGitStatus(projectID: Int64) async {
        guard let cli else {
            gitStatusErrors[projectID] = Self.cliMissingMessage
            return
        }
        guard !gitRefreshing.contains(projectID) else {
            gitRefreshQueued.insert(projectID)
            return
        }
        gitRefreshing.insert(projectID)
        defer { gitRefreshing.remove(projectID) }
        repeat {
            gitRefreshQueued.remove(projectID)
            do {
                applyGitStatus(try await cli.gitStatus(projectID: projectID), projectID: projectID)
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                // The last known status stays, so the button does not vanish.
                gitStatusErrors[projectID] = "Could not read the git status: "
                    + gitFailureText(error, command: "status", projectID: projectID)
            }
        } while gitRefreshQueued.contains(projectID)
    }

    /// The popover opened: the branch list (CLI) and the board's branch
    /// targets (DB) for the badges. Clears the previous popover's messages.
    func loadBranches(project: Workbench) async {
        gitErrors[project.id] = nil
        gitNotices[project.id] = nil
        await reloadBranchList(project: project)
    }

    /// Starts a switch. The first call never carries a confirmation flag:
    /// Go answers `needs_confirmation` for a dirty tree or a live agent, and
    /// the switch waits in `pendingBranchConfirmation` for the owner.
    func switchBranch(_ branch: String, project: Workbench) async {
        guard switchingBranch[project.id] == nil else { return }
        pendingBranchConfirmation[project.id] = nil
        await runSwitch(branch, project: project, stash: false, confirmAgent: false)
    }

    /// The owner confirmed the pending switch: resend it with exactly the
    /// flags the dialog named. The live-session fact is read again, so an
    /// agent started since the first try is still asked about. The dialog
    /// passes the confirmation it showed: dismissing it clears the pending
    /// one, possibly before this runs.
    func confirmPendingSwitch(project: Workbench, _ confirmation: BranchSwitchConfirmation? = nil) async {
        guard switchingBranch[project.id] == nil,
              let pending = confirmation ?? pendingBranchConfirmation[project.id] else { return }
        pendingBranchConfirmation[project.id] = nil
        await runSwitch(pending.branch, project: project, stash: pending.stash, confirmAgent: pending.confirmAgent)
    }

    func cancelPendingSwitch(projectID: Int64) {
        pendingBranchConfirmation[projectID] = nil
    }

    /// "New branch from current…": `git switch -c` from HEAD (no files
    /// change, so no guard). Returns whether the branch was created.
    @discardableResult
    func createBranch(_ name: String, project: Workbench) async -> Bool {
        let id = project.id
        guard switchingBranch[id] == nil else { return false }
        guard let cli else {
            gitErrors[id] = Self.cliMissingMessage
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            gitErrors[id] = "Enter a name for the new branch."
            return false
        }
        gitErrors[id] = nil
        gitNotices[id] = nil
        switchingBranch[id] = trimmed
        defer { switchingBranch[id] = nil }
        let result: WorkbenchGitSwitchResult
        do {
            result = try await cli.gitCreateBranch(projectID: id, name: trimmed)
        } catch {
            gitErrors[id] = "Could not create \(trimmed): \(gitFailureText(error, command: "create", projectID: id))"
            return false
        }
        let created = result.created || result.switched
        let outcome = WorkbenchBranchPresentation.outcome(result)
        gitErrors[id] = outcome.error ?? (created ? nil : "The branch was not created.")
        gitNotices[id] = outcome.notice
        await afterGitWrite(project: project)
        return created
    }

    /// "Copy branch name": the branch, or the hash on a detached HEAD.
    func copyBranchName(projectID: Int64) {
        guard let status = gitStatus[projectID] else { return }
        let text = WorkbenchBranchPresentation.label(status).text
        guard !text.isEmpty else { return }
        copyToPasteboard(text)
    }

    /// The page is on screen: read the status, then follow it — the refs
    /// watcher, app activation and the dirty-dot poll (only while the tab is
    /// what the owner sees).
    func startGitWatching(project: Workbench) async {
        let id = project.id
        gitWatching.insert(id)
        observeAppActivation()
        if gitTimers[id] == nil {
            gitTimers[id] = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.gitPollSleep(Self.gitPollInterval)
                    guard !Task.isCancelled, let self else { return }
                    if self.isTabOnScreen() { await self.refreshGitStatus(projectID: id) }
                }
            }
        }
        await refreshGitStatus(projectID: id)
        // The read above arms the watcher; a status already known (a read
        // coalesced into one in flight) arms it now.
        if let status = gitStatus[id] { armGitWatcher(status, projectID: id) }
    }

    /// The page went away: stop watching. The last status, a switch in
    /// flight and its pending confirmation all stay.
    func stopGitWatching(projectID: Int64) {
        gitWatching.remove(projectID)
        gitTimers.removeValue(forKey: projectID)?.cancel()
        gitWatchers.removeValue(forKey: projectID)?.stop()
        gitWatchedDirs[projectID] = nil
        if gitWatching.isEmpty, let observer = gitActivationObserver {
            gitNotificationCenter.removeObserver(observer)
            gitActivationObserver = nil
        }
    }

    // MARK: - Private

    private func runSwitch(_ branch: String, project: Workbench, stash: Bool, confirmAgent: Bool) async {
        let id = project.id
        guard let cli else {
            gitErrors[id] = Self.cliMissingMessage
            return
        }
        gitErrors[id] = nil
        gitNotices[id] = nil
        switchingBranch[id] = branch
        defer { switchingBranch[id] = nil }
        let agentRunning = terminalCenter?.hasLiveClaudeSession(workbenchID: id, folder: project.folderPath) ?? false
        let result: WorkbenchGitSwitchResult
        do {
            result = try await cli.gitSwitch(projectID: id, branch: branch, stash: stash,
                                             agentRunning: agentRunning, confirmAgent: confirmAgent && agentRunning)
        } catch {
            gitErrors[id] = "Could not switch to \(branch): \(gitFailureText(error, command: "switch", projectID: id))"
            await refreshGitStatus(projectID: id)
            return
        }
        // Go wrote nothing: wait for the owner, no further call.
        if let confirmation = WorkbenchBranchPresentation.confirmation(for: result) {
            pendingBranchConfirmation[id] = confirmation
            return
        }
        let outcome = WorkbenchBranchPresentation.outcome(result)
        gitErrors[id] = outcome.error
        gitNotices[id] = outcome.notice
        await afterGitWrite(project: project)
    }

    /// After a switch or create, whatever its outcome (a failed switch may
    /// have restored a stash): a fresh status read — not the envelope's,
    /// which a refusal may leave empty — and the branch list again.
    private func afterGitWrite(project: Workbench) async {
        await refreshGitStatus(projectID: project.id)
        await reloadBranchList(project: project)
    }

    private func reloadBranchList(project: Workbench) async {
        let id = project.id
        guard let cli else {
            gitErrors[id] = Self.cliMissingMessage
            return
        }
        var problems: [String] = []
        do {
            let list = try await cli.gitBranches(projectID: id)
            gitBranches[id] = list
            if !list.branchesOK { problems.append("Could not list the branches: \(list.branchesError)") }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            problems.append("Could not list the branches: \(gitFailureText(error, command: "branches", projectID: id))")
        }
        do {
            branchTargets[id] = try await dbPool.read { try WorkbenchQueries.branchTargets($0, projectID: id) }
        } catch {
            problems.append("Could not read the board's branches: \(error.localizedDescription)")
        }
        if !problems.isEmpty {
            gitErrors[id] = ([gitErrors[id]].compactMap { $0 } + problems).joined(separator: "\n")
        }
    }

    /// A status git could not read inside the repository is a failed read:
    /// the last good status stays and the error says why.
    private func applyGitStatus(_ status: WorkbenchGitStatus, projectID: Int64) {
        if status.git, !status.statusOK {
            gitStatusErrors[projectID] = "Could not read the git status: \(status.statusError)"
            return
        }
        gitStatus[projectID] = status
        gitStatusErrors[projectID] = nil
        armGitWatcher(status, projectID: projectID)
    }

    /// (Re)creates the refs watcher when the page is watching and the dirs
    /// changed (a worktree moved, `.git` appeared); none outside a repository.
    private func armGitWatcher(_ status: WorkbenchGitStatus, projectID: Int64) {
        guard gitWatching.contains(projectID) else { return }
        let dirs = status.git && !status.gitDir.isEmpty ? [status.gitDir, status.commonDir] : []
        guard dirs != gitWatchedDirs[projectID] else { return }
        gitWatchers.removeValue(forKey: projectID)?.stop()
        gitWatchedDirs[projectID] = dirs
        guard !dirs.isEmpty else { return }
        gitWatchers[projectID] = makeGitWatcher(status.gitDir, status.commonDir) { [weak self] in
            Task { await self?.refreshGitStatus(projectID: projectID) }
        }
    }

    /// The owner's line for a failed call; the raw error goes to the log.
    private func gitFailureText(_ error: Error, command: String, projectID: Int64) -> String {
        print("[WorkbenchGit] workbench git \(command) for workbench \(projectID) failed: \(error)")
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
                    Task { await self.refreshGitStatus(projectID: id) }
                }
            }
        }
    }
}
