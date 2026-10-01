import Foundation
import GRDB
import WatchtowerCore

/// Project and standalone terminal sessions (spec
/// 2026-09-30-project-workspace-sessions §§2–5). Every result is keyed by
/// the session's own project, never the current selection: an action that
/// finishes after the owner selected another project changes only its own
/// project's list and layout (house rule).
extension ProjectsViewModel {
    static let titleRefreshInterval: Duration = .seconds(120)
    /// A resume that fails exits almost at once; a later non-zero exit is
    /// the owner's own session ending.
    static let resumeFailureWindow: TimeInterval = 3
    /// How many "no owner message yet" answers in a row the title poll takes
    /// before it stops asking about a session the owner is not in.
    static let maxNotYetTitledPolls = 5

    /// Where an opened or new session goes in its project's layout.
    enum Placement: Equatable {
        /// A panel click: `WorkspaceLayout.show`.
        case show
        /// Without hiding this pane (Send comments / Open terminal from a
        /// document): `WorkspaceLayout.reveal(_:keeping:)`.
        case keeping(WorkspacePane)
        /// Into this pane's slot (a pane's own picker); a slot gone from
        /// the layout meanwhile falls back to `.show`.
        case replacing(WorkspacePane)
        /// The layout stays as it is: a button inside the session's own pane
        /// (Resume, Restart, Start fresh) must not undo an expansion.
        case inPlace
    }

    /// The selected project's sessions, most recently active first.
    var sessions: [TerminalSession] {
        selectedProjectID.flatMap { terminalSessions[$0] } ?? []
    }

    /// The selected project's layout; setting it persists it. With no
    /// selection it reads `.default` and ignores writes.
    var layout: WorkspaceLayout {
        get { selectedProjectID.map { layout(projectID: $0) } ?? .default }
        set {
            if let selectedProjectID { setLayout(newValue, projectID: selectedProjectID) }
        }
    }

    func layout(projectID: Int64) -> WorkspaceLayout {
        layouts[projectID] ?? WorkspaceLayout.decode(defaults.data(forKey: WorkspaceLayout.key(projectID: projectID)))
    }

    func setLayout(_ layout: WorkspaceLayout, projectID: Int64) {
        layouts[projectID] = layout
        do {
            defaults.set(try JSONEncoder().encode(layout), forKey: WorkspaceLayout.key(projectID: projectID))
        } catch {
            NSLog("ProjectsViewModel: could not save the layout of project %lld: %@", projectID, error.localizedDescription)
        }
    }

    /// Per project; the standalone sessions' error is `standaloneSessionError`.
    var sessionErrors: [Int64: String] {
        var merged: [Int64: String] = [:]
        for key in Set(sessionActionErrors.keys).union(sessionLoadErrors.keys) {
            if let projectID = key, let message = sessionError(projectID: projectID) { merged[projectID] = message }
        }
        return merged
    }

    var standaloneSessionError: String? { sessionError(projectID: nil) }

    private func sessionError(projectID: Int64?) -> String? {
        let parts = [sessionActionErrors[projectID], sessionLoadErrors[projectID]].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// nil = the standalone sessions. false = the load failed and its error
    /// is in `sessionLoadErrors`; the cached list is then stale.
    /// A read older than one already applied is dropped (the list is newer
    /// already), so on `true` the list reflects at least the caller's read.
    /// Only the latest read started prunes the layout: an older one may
    /// predate a session created since and must not drop it.
    @discardableResult
    func loadSessions(projectID: Int64?) async -> Bool {
        guard let projectID else { return await loadStandaloneSessions() }
        let load = projectLoads[projectID, default: SessionLoads()].started + 1
        projectLoads[projectID, default: SessionLoads()].started = load
        do {
            let rows = try await readProjectSessions(projectID)
            let loads = projectLoads[projectID, default: SessionLoads()]
            guard load > loads.applied else { return true }
            projectLoads[projectID]?.applied = load
            terminalSessions[projectID] = rows
            sessionLoadErrors[projectID] = nil
            // A row gone from the list (deleted from another window, or a
            // layout restored from an older run) leaves the layout too.
            if load == loads.started {
                for id in layout(projectID: projectID).sessionIDs where !rows.contains(where: { $0.id == id }) {
                    forgetInLayout(id, projectID: projectID)
                }
            }
            return true
        } catch {
            guard load > projectLoads[projectID, default: SessionLoads()].applied else { return true }
            sessionLoadErrors[projectID] = "Could not load terminal sessions: \(error.localizedDescription)"
            return false
        }
    }

    /// Only the latest read is applied, success or failure: an older one
    /// finishing last must not undo a newer list, unselect a terminal
    /// created in between, or show an error over a fresh list.
    private func loadStandaloneSessions() async -> Bool {
        standaloneLoads += 1
        let load = standaloneLoads
        do {
            let rows = try await dbPool.read { try TerminalSessionQueries.fetchStandalone($0) }
            guard load == standaloneLoads else { return true }
            standaloneSessions = rows
            if let id = selectedStandaloneID, !rows.contains(where: { $0.id == id }) {
                selectedStandaloneID = nil
            }
            sessionLoadErrors[nil] = nil
            return true
        } catch {
            guard load == standaloneLoads else { return true }
            sessionLoadErrors[nil] = "Could not load terminal sessions: \(error.localizedDescription)"
            return false
        }
    }

    func activeSessionID(projectID: Int64) -> Int64? {
        terminalCenter?.activeSession(projectID: projectID)?.id
    }

    // MARK: - Creating

    func newSession(projectID: Int64, placement: Placement = .show) async {
        guard let project = await project(id: projectID) else { return }
        await startNewSession(project: project, title: TerminalSessionNaming.provisional(now: now()), placement: placement)
    }

    /// A terminal outside any project, in `folder`, put on screen (a
    /// standalone terminal replaces the project page). A shell is named
    /// mechanically and never gets an AI title.
    func newStandalone(kind: TerminalSession.Kind, folder: URL) async {
        let title = switch kind {
        case .claude: TerminalSessionNaming.provisional(now: now())
        case .shell: TerminalSessionNaming.shell(shellPath: terminalCenter?.shell(), folder: folder.path)
        }
        let row = await createAndStart(
            .init(projectID: nil, kind: kind, title: title, folderPath: folder.path,
                  claudeSessionID: kind == .claude ? Self.newClaudeSessionID() : nil),
            prompt: nil
        )
        if let row { showStandalone(row.id) }
    }

    /// Creates a `claude` session row with a new Claude session id and starts
    /// it fresh (`--session-id`).
    func startNewSession(project: Project, title: String, prompt: String? = nil, placement: Placement = .show) async {
        await createAndStart(
            .init(projectID: project.id, kind: .claude, title: title, folderPath: project.folderPath,
                  claudeSessionID: Self.newClaudeSessionID()),
            prompt: prompt,
            placement: placement
        )
    }

    /// "Work on it" (spec §4): the target's most recently active session
    /// (resumed, reopened if closed), else a new one named after the target
    /// and started with the fixed work-on prompt. It goes on screen without
    /// hiding the board it was started from (beside it in a split).
    func workOn(targetID: Int64, targetText: String, placement: Placement = .keeping(.board)) async {
        guard workingOnTarget.insert(targetID).inserted else { return }
        defer { workingOnTarget.remove(targetID) }
        let found: (project: Project, rows: [TerminalSession])?
        do {
            found = try await dbPool.read { db in
                guard let projectID = try TargetQueries.fetchByID(db, id: Int(targetID))?.projectID,
                      let project = try ProjectQueries.fetch(db, id: projectID) else { return nil }
                let rows = try TerminalSessionQueries.fetchForTarget(db, targetID: targetID)
                return (project, rows.filter { $0.projectID == projectID })
            }
        } catch {
            setSessionError("Could not read the target: \(error.localizedDescription)", projectID: selectedProjectID)
            return
        }
        guard let found else {
            setSessionError("Target #\(targetID) is not on a project board.", projectID: selectedProjectID)
            return
        }
        if let existing = TerminalSessionPolicy.sessionForTarget(targetID, in: found.rows) {
            await open(existing, placement: placement)
            return
        }
        let text = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        await createAndStart(
            .init(projectID: found.project.id, kind: .claude, title: text.isEmpty ? "Target #\(targetID)" : text,
                  targetID: targetID, folderPath: found.project.folderPath,
                  claudeSessionID: Self.newClaudeSessionID()),
            prompt: TerminalLaunch.workOnTargetPrompt(targetID: targetID),
            placement: placement
        )
    }

    /// "Open terminal": resumes the project's most recently active open
    /// session, or starts a new one when it has none.
    func openMostRecentSession(project: Project, placement: Placement = .show) async {
        guard openingSession.insert(project.id).inserted else { return }
        defer { openingSession.remove(project.id) }
        // A failed load says nothing about the project's sessions: starting a
        // new one would duplicate the session the owner meant to resume.
        guard await loadSessions(projectID: project.id) else { return }
        if let row = terminalSessions[project.id]?.first(where: { !$0.isClosed }) {
            await open(row, placement: placement)
        } else {
            await startNewSession(project: project, title: TerminalSessionNaming.provisional(now: now()), placement: placement)
        }
    }

    // MARK: - Opening and ending

    /// Selects a session: reopens it if closed, marks it active, starts it
    /// (a `claude` row resumes) unless it is running, focuses it and shows it.
    func open(_ session: TerminalSession, placement: Placement = .show) async {
        setSessionError(nil, projectID: session.projectID)
        let row: TerminalSession
        do {
            row = try await dbPool.write { db in
                guard let current = try TerminalSessionQueries.fetch(db, id: session.id) else {
                    throw TerminalSessionQueryError.notFound(session.id)
                }
                if current.isClosed {
                    try TerminalSessionQueries.reopen(db, id: session.id)
                } else {
                    try TerminalSessionQueries.touch(db, id: session.id)
                }
                return try TerminalSessionQueries.fetch(db, id: session.id) ?? current
            }
        } catch {
            await failed(session, "Could not open the session", error)
            return
        }
        resumeFailed.remove(row.id)
        await activate(row, fresh: false, prompt: nil, placement: placement)
    }

    /// "Start fresh" after a failed resume: a new Claude session id under the
    /// same row and title. A shell has no Claude session: it just opens.
    func startFresh(_ session: TerminalSession, placement: Placement = .show) async {
        guard session.kind == .claude else {
            await open(session, placement: placement)
            return
        }
        setSessionError(nil, projectID: session.projectID)
        // A running process would keep its old id: `start` skips a running row.
        await terminalCenter?.close(sessionID: session.id)
        let uuid = Self.newClaudeSessionID()
        let row: TerminalSession
        do {
            row = try await dbPool.write { db in
                guard let current = try TerminalSessionQueries.fetch(db, id: session.id) else {
                    throw TerminalSessionQueryError.notFound(session.id)
                }
                try TerminalSessionQueries.replaceClaudeSessionID(db, id: session.id, uuid: uuid)
                if current.isClosed {
                    try TerminalSessionQueries.reopen(db, id: session.id)
                } else {
                    try TerminalSessionQueries.touch(db, id: session.id)
                }
                return try TerminalSessionQueries.fetch(db, id: session.id) ?? current
            }
        } catch {
            await failed(session, "Could not start the session fresh", error)
            return
        }
        resumeFailed.remove(row.id)
        await activate(row, fresh: true, prompt: nil, placement: placement)
    }

    /// Stops the process and marks the row closed; it stays listed and can
    /// be reopened. Its pane shows another live session of the project that
    /// is not on screen yet, else it leaves the layout.
    func close(_ session: TerminalSession) async {
        setSessionError(nil, projectID: session.projectID)
        await terminalCenter?.close(sessionID: session.id)
        forgetProcessState(session.id)
        do {
            try await dbPool.write { try TerminalSessionQueries.close($0, id: session.id) }
            // Only once the row is closed: a failed write keeps the pane (and
            // its error) where the owner is looking.
            if let projectID = session.projectID { replaceClosedInLayout(session.id, projectID: projectID) }
        } catch {
            setSessionError("Could not close the session: \(error.localizedDescription)", projectID: session.projectID)
        }
        await loadSessions(projectID: session.projectID)
        await refreshTitle(sessionID: session.id)
    }

    /// Closes the process first, then deletes the row and drops it from the
    /// layout. Claude Code's transcript is left alone.
    func delete(_ session: TerminalSession) async {
        setSessionError(nil, projectID: session.projectID)
        await terminalCenter?.close(sessionID: session.id)
        forgetProcessState(session.id)
        titleAttempts[session.id] = nil
        notYetTitledStreak[session.id] = nil
        do {
            try await dbPool.write { try TerminalSessionQueries.delete($0, id: session.id) }
        } catch {
            setSessionError("Could not delete the session: \(error.localizedDescription)", projectID: session.projectID)
            await loadSessions(projectID: session.projectID)
            return
        }
        if let projectID = session.projectID { forgetInLayout(session.id, projectID: projectID) }
        if selectedStandaloneID == session.id { selectedStandaloneID = nil }
        await loadSessions(projectID: session.projectID)
    }

    /// An empty name is refused (the title stays as it was).
    func rename(_ session: TerminalSession, to title: String) async {
        setSessionError(nil, projectID: session.projectID)
        do {
            try await dbPool.write { try TerminalSessionQueries.rename($0, id: session.id, title: title) }
        } catch TerminalSessionQueryError.emptyTitle {
            return
        } catch {
            setSessionError("Could not rename the session: \(error.localizedDescription)", projectID: session.projectID)
            return
        }
        await loadSessions(projectID: session.projectID)
    }

    // MARK: - Titles

    /// Starts the 2-minute AI-title poll over live sessions (spec §5). Once,
    /// from `AppState.initProjects`; calling it again restarts it.
    func startTitleRefresh() {
        titleTask?.cancel()
        titleTask = Task { [weak self] in
            // Ends once the VM is gone: `self` is re-checked around each wait.
            while !Task.isCancelled {
                guard let sleep = self?.titleSleep else { return }
                await sleep(Self.titleRefreshInterval)
                guard let self, !Task.isCancelled else { return }
                await refreshTitles()
            }
        }
    }

    func stopTitleRefresh() {
        titleTask?.cancel()
        titleTask = nil
    }

    /// Asks for an AI title for every live session that still needs one.
    func refreshTitles() async {
        guard let center = terminalCenter else { return }
        for id in center.liveIDs.sorted() {
            await refreshTitle(sessionID: id)
        }
    }

    /// One title attempt for `sessionID` if `TerminalSessionPolicy.needsTitle`
    /// says so. Only a failed call counts as an attempt: `written: false`
    /// (no owner message yet) cost no AI call and must not use the budget up
    /// before the owner has typed; `maxNotYetTitledPolls` of those in a row
    /// pause the poll for that session until the owner switches back to it. A session with no transcript yet cannot
    /// have one, so it spawns no CLI at all. Failures are logged, never shown.
    func refreshTitle(sessionID: Int64) async {
        guard let titleService else { return }
        let row: TerminalSession?
        do {
            row = try await dbPool.read { try TerminalSessionQueries.fetch($0, id: sessionID) }
        } catch {
            NSLog("ProjectsViewModel: could not read session %lld for its title: %@", sessionID, error.localizedDescription)
            return
        }
        guard let row, TerminalSessionPolicy.needsTitle(row, attempts: titleAttempts[sessionID, default: 0]),
              notYetTitledStreak[sessionID, default: 0] < Self.maxNotYetTitledPolls,
              let uuid = row.claudeSessionID, terminalCenter?.transcriptExists(uuid) ?? true else { return }
        do {
            if try await titleService(sessionID).written {
                notYetTitledStreak[sessionID] = nil
                await loadSessions(projectID: row.projectID)
            } else {
                notYetTitledStreak[sessionID, default: 0] += 1
            }
        } catch {
            titleAttempts[sessionID, default: 0] += 1
            NSLog("ProjectsViewModel: title for session %lld failed: %@", sessionID, error.localizedDescription)
        }
    }

    // MARK: - Process exits

    /// The center's exit hook: a relaunch of a stored id (a resume, or a
    /// `--session-id` when no transcript was found) that exits non-zero within
    /// `resumeFailureWindow` of launch is a failed resume. 127 is not: Claude
    /// Code was not found, and Start fresh would fail the same way.
    func sessionExited(_ id: Int64, code: Int32?) {
        guard let started = resumeStarts.removeValue(forKey: id) else { return }
        if let code, code != 0, code != 127, now().timeIntervalSince(started) < Self.resumeFailureWindow {
            resumeFailed.insert(id)
        }
    }

    // MARK: - Private

    private static func newClaudeSessionID() -> String {
        UUID().uuidString.lowercased()
    }

    private func project(id: Int64) async -> Project? {
        if let known = summaries.first(where: { $0.id == id })?.project { return known }
        do {
            if let fetched = try await dbPool.read({ try ProjectQueries.fetch($0, id: id) }) { return fetched }
            setSessionError("Project \(id) no longer exists.", projectID: id)
        } catch {
            setSessionError("Could not read the project: \(error.localizedDescription)", projectID: id)
        }
        return nil
    }

    /// The created row, or nil when it could not be written.
    @discardableResult
    private func createAndStart(
        _ new: TerminalSessionQueries.NewSession, prompt: String?, placement: Placement = .show
    ) async -> TerminalSession? {
        setSessionError(nil, projectID: new.projectID)
        let row: TerminalSession
        do {
            row = try await dbPool.write { try TerminalSessionQueries.create($0, new) }
        } catch {
            setSessionError("Could not create a terminal session: \(error.localizedDescription)", projectID: new.projectID)
            return nil
        }
        await activate(row, fresh: true, prompt: prompt, placement: placement)
        return row
    }

    /// Starts (unless running) and focuses `row`, refreshes its list, places
    /// it in its own project's layout, then titles the session the owner
    /// switched away from.
    private func activate(_ row: TerminalSession, fresh: Bool, prompt: String?, placement: Placement) async {
        let previous = terminalCenter?.focusOrder.last
        notYetTitledStreak[row.id] = nil // the owner is back in it: ask again
        if let center = terminalCenter {
            let mode = center.start(row, fresh: fresh, prompt: prompt)
            switch mode {
            case .resumeClaude?, .newClaude? where !fresh:
                // A relaunch of the stored id: a missed transcript makes it a
                // `--session-id` of an id Claude Code already used, which it
                // refuses at once — only Start fresh (a new id) gets out.
                resumeStarts[row.id] = now()
            case nil:
                break
            default:
                resumeStarts[row.id] = nil
            }
            center.focus(row.id)
        }
        if let projectID = row.projectID {
            var updated = layout(projectID: projectID)
            switch placement {
            case .show: updated.show(.session(row.id))
            case let .keeping(kept): updated.reveal(.session(row.id), keeping: kept)
            case let .replacing(slot):
                if !updated.replace(slot, with: .session(row.id)) { updated.show(.session(row.id)) }
            case .inPlace:
                break
            }
            setLayout(updated, projectID: projectID)
        }
        await loadSessions(projectID: row.projectID)
        if let previous, previous != row.id { await refreshTitle(sessionID: previous) }
    }

    private func failed(_ session: TerminalSession, _ what: String, _ error: Error) async {
        setSessionError("\(what): \(error.localizedDescription)", projectID: session.projectID)
        if case .notFound(_)? = error as? TerminalSessionQueryError, let projectID = session.projectID {
            forgetInLayout(session.id, projectID: projectID)
        }
        await loadSessions(projectID: session.projectID)
    }

    private func replaceClosedInLayout(_ sessionID: Int64, projectID: Int64) {
        var updated = layout(projectID: projectID)
        guard updated.sessionIDs.contains(sessionID) else { return }
        let others = (terminalSessions[projectID] ?? []).filter { $0.id != sessionID }
        var next: TerminalSession?
        if let center = terminalCenter {
            next = TerminalSessionPolicy.activeSession(others, live: center.liveIDs, lastFocused: center.focusOrder)
        }
        if let next, !updated.sessionIDs.contains(next.id) {
            updated.replace(.session(sessionID), with: .session(next.id))
            setLayout(updated, projectID: projectID)
        } else {
            forgetInLayout(sessionID, projectID: projectID)
        }
    }

    private func forgetInLayout(_ sessionID: Int64, projectID: Int64) {
        var updated = layout(projectID: projectID)
        updated.forgetSession(sessionID, fallback: .board)
        if updated != layout(projectID: projectID) { setLayout(updated, projectID: projectID) }
    }

    private func forgetProcessState(_ sessionID: Int64) {
        resumeStarts[sessionID] = nil
        resumeFailed.remove(sessionID)
    }

    private func setSessionError(_ message: String?, projectID: Int64?) {
        sessionActionErrors[projectID] = message
    }
}
