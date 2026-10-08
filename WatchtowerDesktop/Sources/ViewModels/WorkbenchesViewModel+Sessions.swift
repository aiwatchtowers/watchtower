import Foundation
import GRDB
import WatchtowerCore

/// Project and standalone terminal sessions (spec
/// 2026-09-30-project-workspace-sessions §§2–5). Every result is keyed by
/// the session's own project, never the current selection: an action that
/// finishes after the owner selected another project changes only its own
/// project's list and layout (house rule).
extension WorkbenchesViewModel {
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
        /// Without hiding this pane (the Terminal toggle, Work on it):
        /// `WorkspaceLayout.reveal(_:keeping:)`.
        case keeping(WorkspacePane)
        /// Into this pane's slot (a pane's own picker); a slot gone from
        /// the layout meanwhile falls back to `.show`.
        case replacing(WorkspacePane)
        /// The layout stays as it is: a button inside the session's own pane
        /// (Resume, Restart, Start fresh) must not undo an expansion.
        case inPlace
        /// ⌘↵ in the go-to palette, beside this pane:
        /// `WorkspaceLayout.openBeside(_:keeping:)`.
        case beside(WorkspacePane)
        /// Off screen (a start from the phone, mobile POC spec §6.5): the
        /// process starts, but nothing the owner sees changes — no switch
        /// ticket (an owner's switch under way stays the latest), no focus,
        /// no layout change, no title refresh of the session left.
        case background
    }

    /// Which session `startForTarget` opens.
    enum TargetStartMode: Equatable {
        /// Work on it's rule: the target's most recently active session,
        /// else a new one.
        case openExisting
        /// Always a new session.
        case new
    }

    enum TargetStartError: Error, Equatable {
        /// The target is not on any workbench board.
        case notOnBoard
        /// A start for this target (here or a Work on it) is still running.
        case inProgress
        /// A read or write failed; the message says which.
        case failed(String)
    }

    /// The selected project's sessions, most recently active first (the
    /// panel shows `orderedSessions(projectID:)` instead).
    var sessions: [TerminalSession] {
        selectedWorkbenchID.flatMap { terminalSessions[$0] } ?? []
    }

    /// The selected project's layout; setting it persists it. With no
    /// selection it reads `.default` and ignores writes.
    var layout: WorkspaceLayout {
        get { selectedWorkbenchID.map { layout(projectID: $0) } ?? .default }
        set {
            guard let selectedWorkbenchID else { return }
            beginSwitch(projectID: selectedWorkbenchID)
            setLayout(newValue, projectID: selectedWorkbenchID)
        }
    }

    func layout(projectID: Int64) -> WorkspaceLayout {
        layouts[projectID] ?? WorkspaceLayout.decode(defaults.data(forKey: WorkspaceLayout.key(workbenchID: projectID)))
    }

    func setLayout(_ layout: WorkspaceLayout, projectID: Int64) {
        layouts[projectID] = layout
        // The ask drawer sits beside its session's terminal: once that
        // session leaves the screen, the drawer (and the stack's highlight)
        // goes with it. The draft stays, and the drawer comes back with the
        // session once its pane measures itself (board #364,
        // `sessionPaneMeasured`).
        if let sessionID = asks.drawerAsk(projectID: projectID)?.sessionID,
           !layout.visiblePanes.contains(.session(sessionID)) {
            asks.hideDrawer(projectID: projectID)
        }
        do {
            defaults.set(try JSONEncoder().encode(layout), forKey: WorkspaceLayout.key(workbenchID: projectID))
        } catch {
            NSLog("WorkbenchesViewModel: could not save the layout of workbench %lld: %@", projectID, error.localizedDescription)
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
        let load = workbenchLoads[projectID, default: SessionLoads()].started + 1
        workbenchLoads[projectID, default: SessionLoads()].started = load
        do {
            let rows = try await readWorkbenchSessions(projectID)
            let loads = workbenchLoads[projectID, default: SessionLoads()]
            guard load > loads.applied else { return true }
            workbenchLoads[projectID]?.applied = load
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
            guard load > workbenchLoads[projectID, default: SessionLoads()].applied else { return true }
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
        let ticket = beginSwitch(projectID: projectID)
        guard let project = await project(id: projectID) else { return }
        await startNewSession(
            project: project, title: TerminalSessionNaming.provisional(now: now()), placement: placement, ticket: ticket
        )
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
            prompt: nil,
            ticket: beginSwitch(projectID: nil)
        )
        if let row { showStandalone(row.id) }
    }

    /// Creates a `claude` session row with a new Claude session id and starts
    /// it fresh (`--session-id`).
    func startNewSession(
        project: Workbench, title: String, prompt: String? = nil, placement: Placement = .show, ticket: Int? = nil
    ) async {
        await createAndStart(
            .init(projectID: project.id, kind: .claude, title: title, folderPath: project.folderPath,
                  claudeSessionID: Self.newClaudeSessionID()),
            prompt: prompt,
            placement: placement,
            ticket: ticket ?? beginSwitch(projectID: project.id)
        )
    }

    /// "Work on it" (spec §4): the target's most recently active session
    /// (resumed), else a new one named after the target
    /// and started with the fixed work-on prompt. A split keeps the board it
    /// was started from (the session goes beside it); a single pane switches
    /// to the session. `projectID` is the target's own project, which keys a
    /// read error (the selection may change during the read).
    func workOn(
        targetID: Int64, targetText: String, projectID: Int64? = nil, placement: Placement = .keeping(.board)
    ) async {
        // Every failure is on the page already (or logged, if superseded).
        _ = try? await startTarget(
            targetID, title: targetText, prompt: nil, mode: .openExisting, placement: placement,
            askedIn: projectID ?? selectedWorkbenchID
        )
    }

    /// A start on a board target from outside the board's own buttons (the
    /// phone, mobile POC spec §6.5): Work on it's read, reuse rule and launch
    /// path, with the session named after the target's stored text.
    /// `prompt` replaces the work-on prompt, and `planFirst` follows either
    /// with `TerminalLaunch.planFirstSuffix`; both apply only to a new
    /// session (a reopened one resumes its conversation). With `.background`
    /// a failure is thrown and logged, never put on the owner's page.
    @discardableResult
    func startForTarget(
        targetID: Int64, prompt: String?, mode: TargetStartMode, placement: Placement, planFirst: Bool = false
    ) async throws -> TerminalSession {
        try await startTarget(
            targetID, title: nil, prompt: prompt, mode: mode, placement: placement,
            askedIn: selectedWorkbenchID, planFirst: planFirst
        )
    }

    /// `title` nil = the target's stored text. `askedIn` keys the read's
    /// switch ticket and errors (the target's workbench is known only after
    /// the read; the page's is the one it almost always is).
    private func startTarget(
        _ targetID: Int64,
        title: String?,
        prompt: String?,
        mode: TargetStartMode,
        placement: Placement,
        askedIn: Int64?,
        planFirst: Bool = false
    ) async throws -> TerminalSession {
        guard workingOnTarget.insert(targetID).inserted else { throw TargetStartError.inProgress }
        defer { workingOnTarget.remove(targetID) }
        var ticket = placement == .background ? nil : beginSwitch(projectID: askedIn)
        let found: TargetSessions?
        do {
            found = try await readTargetSessions(targetID)
        } catch {
            let message = "Could not read the target: \(error.localizedDescription)"
            reportStartError(message, projectID: askedIn, ticket: ticket)
            throw TargetStartError.failed(message)
        }
        guard let found else {
            reportStartError("Target #\(targetID) is not on a workbench board.", projectID: askedIn, ticket: ticket)
            throw TargetStartError.notOnBoard
        }
        if ticket != nil, found.project.id != askedIn { ticket = beginSwitch(projectID: found.project.id) }
        if mode == .openExisting, let existing = TerminalSessionPolicy.sessionForTarget(targetID, in: found.rows) {
            return try await reopen(existing, placement: placement, ticket: ticket)
        }
        let text = (title ?? found.targetText).trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = prompt ?? TerminalLaunch.workOnTargetPrompt(
            targetID: targetID, vocabulary: vocabulary(projectID: found.project.id)
        )
        return try await createAndActivate(
            .init(projectID: found.project.id, kind: .claude, title: text.isEmpty ? "Target #\(targetID)" : text,
                  targetID: targetID, folderPath: found.project.folderPath,
                  claudeSessionID: Self.newClaudeSessionID()),
            prompt: planFirst ? "\(brief) \(TerminalLaunch.planFirstSuffix)" : brief,
            placement: placement,
            ticket: ticket
        )
    }

    /// A target's own workbench, its text, and the sessions of that
    /// workbench working on it.
    typealias TargetSessions = (project: Workbench, targetText: String, rows: [TerminalSession])

    /// nil when the target is not on a workbench board.
    private func readTargetSessions(_ targetID: Int64) async throws -> TargetSessions? {
        try await dbPool.read { db in
            guard let target = try TargetQueries.fetchByID(db, id: Int(targetID)),
                  let projectID = target.workbenchID,
                  let project = try WorkbenchQueries.fetch(db, id: projectID) else { return nil }
            let rows = try TerminalSessionQueries.fetchForTarget(db, targetID: targetID)
            return (project, target.text, rows.filter { $0.projectID == projectID })
        }
    }

    /// "Open terminal": resumes the project's most recently active session,
    /// or starts a new one when it has none.
    func openMostRecentSession(project: Workbench, placement: Placement = .show) async {
        guard openingSession.insert(project.id).inserted else { return }
        defer { openingSession.remove(project.id) }
        let ticket = beginSwitch(projectID: project.id)
        // A failed load says nothing about the project's sessions: starting a
        // new one would duplicate the session the owner meant to resume.
        guard await loadSessions(projectID: project.id) else { return }
        if let row = terminalSessions[project.id]?.first {
            await open(row, placement: placement, ticket: ticket)
        } else {
            await startNewSession(
                project: project, title: TerminalSessionNaming.provisional(now: now()), placement: placement, ticket: ticket
            )
        }
    }

    // MARK: - Opening and ending

    /// Selects a session: marks it active, starts it
    /// (a `claude` row resumes) unless it is running, focuses it and shows it.
    /// `ticket` is the switch's `beginSwitch` when the caller took it before
    /// an await of its own; otherwise it is taken here.
    func open(_ session: TerminalSession, placement: Placement = .show, ticket: Int? = nil) async {
        let ticket = placement == .background ? nil : ticket ?? beginSwitch(projectID: session.projectID)
        // A failure is reported already (`reopen`).
        _ = try? await reopen(session, placement: placement, ticket: ticket)
    }

    /// `open` past its ticket; nil only for `.background`. Throws
    /// `TargetStartError.failed` once the failure is reported.
    private func reopen(_ session: TerminalSession, placement: Placement, ticket: Int?) async throws -> TerminalSession {
        if let ticket { clearSwitchError(projectID: session.projectID, ticket: ticket) }
        let row: TerminalSession
        do {
            row = try await dbPool.write { db in
                guard let current = try TerminalSessionQueries.fetch(db, id: session.id) else {
                    throw TerminalSessionQueryError.notFound(session.id)
                }
                try TerminalSessionQueries.touch(db, id: session.id)
                return try TerminalSessionQueries.fetch(db, id: session.id) ?? current
            }
        } catch {
            await failed(session, "Could not open the session", error, ticket: ticket, background: ticket == nil)
            throw TargetStartError.failed("Could not open the session: \(error.localizedDescription)")
        }
        resumeFailed.remove(row.id)
        await activate(row, fresh: false, prompt: nil, placement: placement, ticket: ticket)
        return row
    }

    /// "Start fresh" after a failed resume: a new Claude session id under the
    /// same row and title. A shell has no Claude session: it just opens.
    func startFresh(_ session: TerminalSession, placement: Placement = .show) async {
        let ticket = beginSwitch(projectID: session.projectID)
        guard session.kind == .claude else {
            await open(session, placement: placement, ticket: ticket)
            return
        }
        clearSwitchError(projectID: session.projectID, ticket: ticket)
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
                try TerminalSessionQueries.touch(db, id: session.id)
                return try TerminalSessionQueries.fetch(db, id: session.id) ?? current
            }
        } catch {
            await failed(session, "Could not start the session fresh", error, ticket: ticket)
            return
        }
        resumeFailed.remove(row.id)
        await activate(row, fresh: true, prompt: nil, placement: placement, ticket: ticket)
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
            // `failed` also drops a session deleted elsewhere from the list and pane.
            await failed(session, "Could not rename the session", error)
            return
        }
        await loadSessions(projectID: session.projectID)
    }

    // MARK: - Titles

    /// Starts the 2-minute AI-title poll over live sessions (spec §5). Once,
    /// from `AppState.initWorkbenches`; calling it again restarts it.
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
            NSLog("WorkbenchesViewModel: could not read session %lld for its title: %@", sessionID, error.localizedDescription)
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
            NSLog("WorkbenchesViewModel: title for session %lld failed: %@", sessionID, error.localizedDescription)
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

    private func project(id: Int64) async -> Workbench? {
        if let known = summaries.first(where: { $0.id == id })?.project { return known }
        do {
            if let fetched = try await dbPool.read({ try WorkbenchQueries.fetch($0, id: id) }) { return fetched }
            setSessionError("Workbench \(id) no longer exists.", projectID: id)
        } catch {
            setSessionError("Could not read the workbench: \(error.localizedDescription)", projectID: id)
        }
        return nil
    }

    /// The created row, or nil when it could not be written (the error is
    /// reported already).
    @discardableResult
    private func createAndStart(
        _ new: TerminalSessionQueries.NewSession, prompt: String?, placement: Placement = .show, ticket: Int
    ) async -> TerminalSession? {
        try? await createAndActivate(new, prompt: prompt, placement: placement, ticket: ticket)
    }

    /// `createAndStart` that throws `TargetStartError.failed` once the
    /// failure is reported. `ticket` is nil only for `.background`.
    private func createAndActivate(
        _ new: TerminalSessionQueries.NewSession, prompt: String?, placement: Placement, ticket: Int?
    ) async throws -> TerminalSession {
        if let ticket { clearSwitchError(projectID: new.projectID, ticket: ticket) }
        let row: TerminalSession
        do {
            row = try await dbPool.write { try TerminalSessionQueries.create($0, new) }
        } catch {
            let message = "Could not create a terminal session: \(error.localizedDescription)"
            reportStartError(message, projectID: new.projectID, ticket: ticket)
            throw TargetStartError.failed(message)
        }
        await activate(row, fresh: true, prompt: prompt, placement: placement, ticket: ticket)
        return row
    }

    /// An owner's switch reports on the page (`reportSwitchError`); a
    /// background start (no ticket) only logs — its caller gets the error,
    /// and the owner's page is not its to change.
    private func reportStartError(_ message: String, projectID: Int64?, ticket: Int?) {
        guard let ticket else {
            NSLog("WorkbenchesViewModel: background session start failed: %@", message)
            return
        }
        reportSwitchError(message, projectID: projectID, ticket: ticket)
    }

    /// Starts (unless running) and focuses `row`, refreshes its list, places
    /// it in its own project's layout, then titles the session the owner
    /// switched away from. A switch superseded by a later one (`beginSwitch`)
    /// only starts its session: the later switch decides what is focused
    /// and on screen. A background start (`ticket` nil, `.background`) is
    /// never the latest switch: it only starts its session and refreshes the
    /// list.
    private func activate(_ row: TerminalSession, fresh: Bool, prompt: String?, placement: Placement, ticket: Int?) async {
        let isLatest = ticket.map { isLatestSwitch($0, projectID: row.projectID) } ?? false
        let previous = terminalCenter?.focusOrder.last
        if ticket != nil { notYetTitledStreak[row.id] = nil } // the owner is back in it: ask again
        if let center = terminalCenter {
            let mode = center.start(row, fresh: fresh, prompt: prompt)
            switch mode {
            case .resumeClaude?:
                resumeStarts[row.id] = now()
            case .newClaude? where !fresh:
                // A relaunch of the stored id: a missed transcript makes it a
                // `--session-id` of an id Claude Code already used, which it
                // refuses at once — only Start fresh (a new id) gets out.
                resumeStarts[row.id] = now()
            case nil:
                break
            default:
                resumeStarts[row.id] = nil
            }
            if isLatest { center.focus(row.id) }
        }
        if isLatest, let projectID = row.projectID {
            setLayout(placing(row.id, placement, in: layout(projectID: projectID)), projectID: projectID)
        }
        await loadSessions(projectID: row.projectID)
        if isLatest, let previous, previous != row.id { await refreshTitle(sessionID: previous) }
    }

    /// `layout` with session `id` placed the way `placement` says.
    private func placing(_ id: Int64, _ placement: Placement, in layout: WorkspaceLayout) -> WorkspaceLayout {
        var updated = layout
        switch placement {
        case .show: updated.show(.session(id))
        case let .keeping(kept): updated.reveal(.session(id), keeping: kept)
        case let .replacing(slot):
            if !updated.replace(slot, with: .session(id)) { updated.show(.session(id)) }
        case .inPlace:
            break
        case let .beside(kept): updated.openBeside(.session(id), keeping: kept)
        case .background:
            break
        }
        return updated
    }

    /// `background`: logged, never on the page (`reportStartError`).
    private func failed(
        _ session: TerminalSession, _ what: String, _ error: Error, ticket: Int? = nil, background: Bool = false
    ) async {
        let message = "\(what): \(error.localizedDescription)"
        if background {
            reportStartError(message, projectID: session.projectID, ticket: nil)
        } else if let ticket {
            reportSwitchError(message, projectID: session.projectID, ticket: ticket)
        } else {
            setSessionError(message, projectID: session.projectID)
        }
        if case .notFound(_)? = error as? TerminalSessionQueryError, let projectID = session.projectID {
            forgetInLayout(session.id, projectID: projectID)
        }
        await loadSessions(projectID: session.projectID)
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
