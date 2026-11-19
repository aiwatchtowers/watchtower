import Foundation
import Observation
import os
import WatchtowerCore

/// How one listed row's relaunch after the v1-host restart went
/// (`WorkbenchesViewModel.relaunchAfterHostRestart`).
enum HostRestartRelaunch: Equatable {
    /// Running again with its conversation (or already running).
    case launched
    /// No transcript or rollout to resume: left in the resume-failure state.
    case noConversation
    /// Did not start; the reason is in its pane. No cleanup ran.
    case failed(String)
    /// The row no longer exists.
    case rowGone
    /// Could not be tried (its row was not readable): it stays in the list.
    case notYet(String)

    /// The outcome's kind for the log: no reason text (FILES-01).
    var logKind: String {
        switch self {
        case .launched: "launched"
        case .noConversation: "no_conversation"
        case .failed: "failed"
        case .rowGone: "row_gone"
        case .notYet: "not_yet"
        }
    }
}

/// The one-time restart of live sessions from a v1 session host into a v2
/// one (go hub spec §8 p. 4b, asks #813, #814 — a one-time PROJ-20
/// exception). The app update leaves the old host running with the old
/// app's sessions; the Go hub never talks to it. At launch, after the
/// reattach (which leaves the list's rows to this step), `runIfNeeded`
/// looks at the host:
///
/// 0. a v1 host with live runs and no restart list: the notice waits for
///    **Continue** (`waitingForContinue`). Nothing else happens until it is
///    pressed; a quit leaves the old host and its sessions, and the notice
///    comes back next launch.
/// 1. Continue: the runs of every scope are listed as a v1 client and
///    written to the restart list (`HostRestartList`) before anything is
///    touched; from here until a v2 host answers no session launches
///    (`TerminalCenter.launchesHeldForHostRestart`);
/// 2. each live run is stopped as Stop Sessions stops it — dropped from the
///    terminal center first, then signalled (`TerminalCenter
///    .stopForHostRestart`), so no PROJ-18 cleanup runs — and forgotten. The
///    host is listed again: a run that appeared meanwhile is listed and
///    stopped too. The old host gets SIGTERM once a fresh Hello confirms its
///    pid, and a v2 host is started through the usual ensure path;
/// 3. this workspace's listed rows relaunch with resume, each removed from
///    the list once its relaunch ended. Other workspaces' rows wait in the
///    list for that workspace's launch, which runs step 3 for them
///    (`waitingWorkspaces` feeds the "N sessions wait to resume" line).
///
/// A list left by an interrupted run is picked up at the next launch with
/// no notice (Continue was pressed): a v1 host still up is handled from
/// step 1, rows already relaunched are not in the list any more. A list
/// that cannot be read stops everything until the owner retries or sets it
/// aside. Main actor.
@MainActor
@Observable
final class HostRestartStep {
    enum Phase: Equatable {
        /// Before the launch's look (nothing drawn, not settled).
        case checking
        case notNeeded
        case waitingForContinue
        case stopping(done: Int, total: Int)
        case relaunching(done: Int, total: Int)
        case finished
        case failed(String)
        /// The list on disk cannot be read: kept as it is, Retry or Set Aside.
        case listUnreadable
    }

    /// Another workspace whose sessions wait in the list.
    struct WaitingWorkspace: Equatable, Identifiable {
        let name: String
        let count: Int
        var id: String { name }
        var line: String { HostRestartStep.waitLine(count) }
    }

    /// What the notice shows for a phase; nil draws nothing.
    struct Notice: Equatable {
        let text: String
        let detail: String?
        let isError: Bool
        /// 0…1 while busy.
        let progress: Double?
        let buttonTitle: String
        let buttonEnabled: Bool
        /// A second, quiet action (Set Aside for an unreadable list).
        var secondaryTitle: String?
    }

    // MARK: Copy (pinned by `HostRestartStepTests.testCopyIsInTheModel`)

    nonisolated static let noticeText = "Running sessions restart once with this update; their conversations continue"
    nonisolated static let continueTitle = "Continue"
    nonisolated static let retryTitle = "Retry"
    nonisolated static let setAsideTitle = "Set Aside"
    nonisolated static let clearTitle = "Clear"
    nonisolated static let failedTitle = "Sessions could not be restarted"
    nonisolated static let readFailed = "Watchtower could not read the running sessions. Your sessions were not changed."
    nonisolated static let saveFailed = "Watchtower could not save the list of running sessions. Your sessions were not changed."
    nonisolated static let rereadFailed = "Watchtower could not read the old session host again. Your sessions resume on Retry."
    nonisolated static let newRunDuringRestart = "A session started during the restart. Your sessions resume on Retry."
    nonisolated static let oldHostUnconfirmed = "Watchtower could not confirm the old session host. Your sessions resume on Retry."
    nonisolated static let oldHostKept = "The old session host did not stop. Your sessions resume on Retry."
    nonisolated static let hostDidNotStart = "The session host did not start. Your sessions resume on Retry."
    nonisolated static let workbenchesNotReady = "The workbenches are not loaded. Your sessions resume on Retry."
    nonisolated static let relaunchIncomplete = "Some sessions did not resume yet. They resume on Retry."
    nonisolated static let listUnreadableTitle = "The list of sessions to resume could not be read"
    nonisolated static let listUnreadableDetail = "Your sessions were not changed. Retry reads the list again; "
        + "Set Aside keeps it as session-host-restart.json.corrupt and goes on without it."
    nonisolated static let setAsideFailed = "Watchtower could not set the list aside. Your sessions were not changed."

    nonisolated static func waitLine(_ count: Int) -> String {
        count == 1 ? "1 session waits to resume" : "\(count) sessions wait to resume"
    }

    /// Rows of a workspace whose database is no longer on this Mac.
    nonisolated static func orphanLine(_ count: Int) -> String {
        count == 1
            ? "1 session waits to resume in a workspace that is no longer here"
            : "\(count) sessions wait to resume in a workspace that is no longer here"
    }

    nonisolated static func stoppingLine(done: Int, total: Int) -> String {
        "Stopping sessions… \(done) of \(total)"
    }

    nonisolated static func relaunchingLine(done: Int, total: Int) -> String {
        "Resuming sessions… \(done) of \(total)"
    }

    nonisolated static func notice(for phase: Phase) -> Notice? {
        switch phase {
        case .checking, .notNeeded, .finished:
            return nil
        case .waitingForContinue:
            return Notice(text: noticeText, detail: nil, isError: false, progress: nil,
                          buttonTitle: continueTitle, buttonEnabled: true)
        case let .stopping(done, total):
            return Notice(text: stoppingLine(done: done, total: total), detail: nil, isError: false,
                          progress: fraction(done, total), buttonTitle: continueTitle, buttonEnabled: false)
        case let .relaunching(done, total):
            return Notice(text: relaunchingLine(done: done, total: total), detail: nil, isError: false,
                          progress: fraction(done, total), buttonTitle: continueTitle, buttonEnabled: false)
        case let .failed(reason):
            return Notice(text: failedTitle, detail: reason, isError: true, progress: nil,
                          buttonTitle: retryTitle, buttonEnabled: true)
        case .listUnreadable:
            return Notice(text: listUnreadableTitle, detail: listUnreadableDetail, isError: true, progress: nil,
                          buttonTitle: retryTitle, buttonEnabled: true, secondaryTitle: setAsideTitle)
        }
    }

    nonisolated private static func fraction(_ done: Int, _ total: Int) -> Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    // MARK: State

    private(set) var phase: Phase = .checking {
        didSet { if isSettled { releaseSettleWaiters() } }
    }

    private(set) var waitingWorkspaces: [WaitingWorkspace] = []
    /// Listed rows of workspaces that are no longer here (`orphanLine`).
    private(set) var orphanedCount = 0
    var notice: Notice? { Self.notice(for: phase) }

    /// Whether a v2 host serves the socket (the old one replaced, or never
    /// there): what the hub's adoption needs.
    private var hostReplaced = false

    /// Done for the hub's purposes: nothing to do, all done, or a failure
    /// left once a v2 host answers (only relaunches are left to Retry).
    /// Never while the notice waits for Continue or a v1 host still answers.
    var isSettled: Bool {
        switch phase {
        case .finished, .notNeeded: true
        case .failed: hostReplaced
        default: false
        }
    }

    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once `isSettled` (go hub plan 3 Task 22: the adoption awaits
    /// it). Never at `waitingForContinue`.
    func waitUntilSettled() async {
        if isSettled { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    private func releaseSettleWaiters() {
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "HostRestart")
    /// How long the old host gets to exit after SIGTERM, and the poll step.
    static let hostExitWait: Duration = .seconds(5)
    static let hostExitPoll: Duration = .milliseconds(100)
    /// How often step 2 lists the old host again for runs that appeared.
    static let relistRounds = 3

    private let center: TerminalCenter
    private let listURL: URL
    private let workbenches: () -> WorkbenchesViewModel?
    /// Other workspaces' names by scope (`SessionHostPaths.scope` of each
    /// workspace database). A seam for tests.
    var workspaceNames: () -> [String: String] = { HostRestartStep.liveWorkspaceNames() }
    /// Signals the old host (`kill`). A seam for tests.
    var signalHost: (pid_t, Int32) -> Void = { _ = kill($0, $1) }
    /// Whether the old host still runs. A seam for tests.
    var hostIsAlive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var working = false

    init(
        center: TerminalCenter,
        listURL: URL = HostRestartList.defaultURL(),
        workbenches: @escaping () -> WorkbenchesViewModel?
    ) {
        self.center = center
        self.listURL = listURL
        self.workbenches = workbenches
    }

    // MARK: Entry points

    /// The launch's look at the session host, once the reattach is done
    /// (see the type). Returns once the notice waits, or the work it could
    /// do without the owner is done.
    func runIfNeeded() async {
        await workbenches()?.hostReattach?.value
        await work { await self.decide(continuePressed: false) }
    }

    /// The notice's Continue, and Retry after a failure or an unreadable list.
    func pressContinue() async {
        switch phase {
        case .waitingForContinue, .failed, .listUnreadable: break
        default: return
        }
        await work { await self.decide(continuePressed: true) }
    }

    /// Set Aside on an unreadable list: the file becomes `<name>.corrupt`
    /// (never deleted), then the step looks again as at launch.
    func pressSetAside() async {
        guard phase == .listUnreadable else { return }
        await work {
            do {
                try HostRestartList.setAside(self.listURL)
            } catch {
                Self.logger.error("restart list set aside: \(error.localizedDescription, privacy: .private)")
                self.phase = .failed(Self.setAsideFailed)
                return
            }
            await self.decide(continuePressed: false)
        }
    }

    /// Clear on the "no longer here" line: drops the rows of workspaces
    /// whose database is gone.
    func clearOrphans() {
        guard case var .list(list) = HostRestartList.stored(at: listURL) else { return }
        let names = workspaceNames()
        let scope = center.sessionHostScope
        list.rows.removeAll { !HostRestartList.row($0, isIn: scope) && names[$0.scope] == nil }
        do {
            try list.save(to: listURL)
        } catch {
            Self.logger.error("restart list clear: \(error.localizedDescription, privacy: .private)")
        }
        refreshWaiting()
    }

    private func work(_ body: () async -> Void) async {
        guard !working else { return }
        working = true
        await body()
        working = false
        refreshWaiting()
    }

    /// Reads the list and the host and does what is due.
    private func decide(continuePressed: Bool) async {
        let list: HostRestartList?
        switch HostRestartList.stored(at: listURL) {
        case .unreadable:
            phase = .listUnreadable
            return
        case .absent: list = nil
        case let .list(stored): list = stored
        }
        let mine = list?.rows(in: center.sessionHostScope) ?? []
        guard let client = await center.connectedSessionHost() else {
            phase = mine.isEmpty ? .notNeeded : .failed(Self.hostDidNotStart)
            return
        }
        if client.speaksV2 {
            hostReplaced = true
            if mine.isEmpty { phase = .notNeeded } else { await relaunch(list ?? HostRestartList()) }
            return
        }
        hostReplaced = false
        // A v1 host. A list on disk means Continue was pressed already.
        if list != nil || continuePressed {
            await restart(client)
            return
        }
        do {
            let live = try await client.list().filter { !$0.exited }
            if live.isEmpty {
                // Nothing runs to restart: the old host is replaced quietly.
                await restart(client)
            } else {
                phase = .waitingForContinue
            }
        } catch {
            // Continue lists again; a session is never stopped unseen.
            Self.logger.error("v1 host list at launch: \(String(describing: error), privacy: .private)")
            phase = .waitingForContinue
        }
    }

    // MARK: Steps

    private struct RunKey: Hashable {
        let scope: String
        let row: Int64
        let run: String
        init(_ info: SessionHostSessionInfo) {
            scope = info.scope
            row = info.row
            run = info.run
        }
    }

    /// Steps 1–3 against a v1 host.
    private func restart(_ client: SessionHostClient) async {
        // Step 1: list every scope's runs and write them down first.
        guard let listed = await listAndSave(client: client, into: nil) else { return }
        let hostPID = client.hostPID
        center.launchesHeldForHostRestart = true
        defer { center.launchesHeldForHostRestart = false }
        // Step 2: stop every live run at once (one grace, not N).
        var state = Stopping(list: listed, seen: Set(listed.runs.map(RunKey.init)),
                             total: listed.runs.filter { !$0.exited }.count)
        phase = .stopping(done: 0, total: state.total)
        state.done = await stop(listed.runs, done: 0, total: state.total)
        // Runs started meanwhile join the list; stopped ones linger only to be forgotten.
        guard await joinNewRuns(client, &state, rounds: Self.relistRounds) else { return }
        // The old host: SIGTERM only to the pid a fresh Hello confirms, after
        // one more look, so no run started during the confirm dies unlisted.
        if let pid = hostPID {
            guard await client.helloPID() == pid, pid > 0 else {
                phase = .failed(Self.oldHostUnconfirmed)
                return
            }
            guard await joinNewRuns(client, &state, rounds: 2), await terminateOldHost(pid_t(pid)) else { return }
        }
        client.dropConnection()
        guard await client.ensureRunning() else {
            phase = .failed(Self.hostDidNotStart)
            return
        }
        guard client.speaksV2 else {
            client.dropConnection()
            phase = .failed(Self.oldHostKept)
            return
        }
        hostReplaced = true
        center.launchesHeldForHostRestart = false
        // Step 3.
        await relaunch(state.list.saved)
    }

    /// Step 2's running state: the list on disk with the runs it came from,
    /// every run met since, and the live-run progress.
    private struct Stopping {
        var list: Listed
        var seen: Set<RunKey>
        var total: Int
        var done = 0
    }

    /// Lists the old host up to `rounds` times: runs already met are
    /// forgotten again, new ones are listed and stopped. True once a list
    /// shows nothing new; false (the phase says why) when a run still
    /// appears in the last round or a read or save fails.
    private func joinNewRuns(_ client: SessionHostClient, _ state: inout Stopping, rounds: Int) async -> Bool {
        for round in 1...rounds {
            let again: [SessionHostSessionInfo]
            do {
                again = try await client.list()
            } catch {
                phase = .failed(Self.rereadFailed)
                return false
            }
            let seen = state.seen
            let fresh = again.filter { !seen.contains(RunKey($0)) }
            for info in again where seen.contains(RunKey(info)) {
                await client.forget(row: info.row, run: info.run)
            }
            guard !fresh.isEmpty else { return true }
            guard round < rounds else {
                phase = .failed(Self.newRunDuringRestart)
                return false
            }
            guard let merged = await listAndSave(client: client, into: state.list.saved, runs: fresh) else { return false }
            state.list = merged
            state.seen.formUnion(fresh.map(RunKey.init))
            state.total += fresh.filter { !$0.exited }.count
            state.done = await stop(fresh, done: state.done, total: state.total)
        }
        return true
    }

    /// SIGTERM to the confirmed old host, then up to `hostExitWait` for it
    /// to go; false (`oldHostKept`) when it stays.
    private func terminateOldHost(_ pid: pid_t) async -> Bool {
        signalHost(pid, SIGTERM)
        var waited: Duration = .zero
        while hostIsAlive(pid), waited < Self.hostExitWait {
            await sleep(Self.hostExitPoll)
            waited += Self.hostExitPoll
        }
        guard !hostIsAlive(pid) else {
            phase = .failed(Self.oldHostKept)
            return false
        }
        return true
    }

    /// Stops `runs` concurrently; returns the live runs stopped so far.
    private func stop(_ runs: [SessionHostSessionInfo], done start: Int, total: Int) async -> Int {
        var done = start
        await withTaskGroup(of: Bool.self) { group in
            for info in runs {
                group.addTask { @MainActor in
                    await self.center.stopForHostRestart(info)
                    return !info.exited
                }
            }
            for await wasLive in group where wasLive {
                done += 1
                phase = .stopping(done: done, total: total)
            }
        }
        return done
    }

    /// The list step 1 wrote, with the runs it came from.
    private struct Listed {
        let saved: HostRestartList
        let runs: [SessionHostSessionInfo]
    }

    /// Lists the host (or takes `runs`), merges the runs' rows into the list
    /// on disk (or `into`) and saves it. nil — the phase says why — when
    /// the host or the rows cannot be read, the list on disk cannot be read,
    /// or the save failed; nothing was stopped then.
    private func listAndSave(
        client: SessionHostClient, into known: HostRestartList?, runs given: [SessionHostSessionInfo]? = nil
    ) async -> Listed? {
        let runs: [SessionHostSessionInfo]
        let mine: [Int64: TerminalSession]
        do {
            if let given { runs = given } else { runs = try await client.list() }
            mine = try await thisScopesRows(runs)
        } catch {
            Self.logger.error("v1 host restart, list: \(String(describing: error), privacy: .private)")
            phase = .failed(given == nil ? Self.readFailed : Self.rereadFailed)
            return nil
        }
        var base: HostRestartList
        if let known {
            base = known
        } else {
            switch HostRestartList.stored(at: listURL) {
            case .unreadable:
                phase = .listUnreadable
                return nil
            case .absent: base = HostRestartList()
            case let .list(stored): base = stored
            }
        }
        base = listRows(of: runs, into: base, rows: mine)
        do {
            try base.save(to: listURL)
        } catch {
            Self.logger.error("v1 host restart, save: \(error.localizedDescription, privacy: .private)")
            phase = .failed(given == nil ? Self.saveFailed : Self.rereadFailed)
            return nil
        }
        return Listed(saved: base, runs: runs)
    }

    /// The rows step 1 lists: the newest live run of each scope and row. A
    /// row of this workspace is listed only when it still exists (the
    /// reattach stops a run whose row is gone); another workspace's rows
    /// are listed as the host names them, read from their own database at
    /// their relaunch.
    private func listRows(
        of runs: [SessionHostSessionInfo], into list: HostRestartList, rows mine: [Int64: TerminalSession]
    ) -> HostRestartList {
        let scope = center.sessionHostScope
        var list = list
        var seen = Set<String>()
        for info in runs.filter({ !$0.exited }).sorted(by: { $0.startedAtMs > $1.startedAtMs }) {
            guard seen.insert("\(info.scope)/\(info.row)").inserted else { continue }
            if info.scope.isEmpty || info.scope == scope {
                guard let row = mine[info.row] else { continue }
                list.merge([HostRestartList.Row(scope: info.scope, rowID: info.row,
                                                agent: row.kind.agent?.rawValue ?? "",
                                                resumeID: row.claudeSessionID ?? "")])
            } else {
                list.merge([HostRestartList.Row(scope: info.scope, rowID: info.row, agent: "", resumeID: "")])
            }
        }
        return list
    }

    private func thisScopesRows(_ runs: [SessionHostSessionInfo]) async throws -> [Int64: TerminalSession] {
        let scope = center.sessionHostScope
        let ids = runs.filter { !$0.exited && ($0.scope.isEmpty || $0.scope == scope) }.map(\.row)
        guard !ids.isEmpty else { return [:] }
        guard let vm = workbenches() else { throw HostRestartError.noWorkbenches }
        return try await vm.hostRestartRows(ids)
    }

    /// Step 3: this workspace's listed rows, one at a time. A row leaves the
    /// list once its relaunch ended (running, resume failure, a reason in
    /// its pane, or gone); one that could not be tried stays for Retry.
    private func relaunch(_ start: HostRestartList) async {
        guard let vm = workbenches() else {
            phase = .failed(Self.workbenchesNotReady)
            return
        }
        var list = start
        let mine = list.rows(in: center.sessionHostScope)
        var pending = false
        phase = .relaunching(done: 0, total: mine.count)
        for (index, row) in mine.enumerated() {
            let outcome = await vm.relaunchAfterHostRestart(rowID: row.rowID)
            if outcome != .launched {
                Self.logger.info("v1 host restart: row \(row.rowID) \(outcome.logKind, privacy: .public)")
            }
            if case .notYet = outcome {
                pending = true
            } else {
                list.remove(scope: row.scope, rowID: row.rowID)
                do {
                    try list.save(to: listURL)
                } catch {
                    // The next launch finds the row running and skips it.
                    Self.logger.error("v1 host restart, save: \(error.localizedDescription, privacy: .private)")
                }
            }
            phase = .relaunching(done: index + 1, total: mine.count)
        }
        phase = pending ? .failed(Self.relaunchIncomplete) : .finished
    }

    // MARK: Wait lines

    /// Recomputes the other workspaces' wait lines from the list on disk.
    func refreshWaiting() {
        guard case let .list(list) = HostRestartList.stored(at: listURL) else {
            waitingWorkspaces = []
            orphanedCount = 0
            return
        }
        let counts = list.waiting(besides: center.sessionHostScope)
        let names = counts.isEmpty ? [:] : workspaceNames()
        var found: [WaitingWorkspace] = []
        var orphaned = 0
        for (scope, count) in counts {
            if let name = names[scope] {
                found.append(WaitingWorkspace(name: name, count: count))
            } else {
                orphaned += count
            }
        }
        waitingWorkspaces = found.sorted { $0.name < $1.name }
        orphanedCount = orphaned
    }

    /// Every workspace holding a database, by its session host scope.
    nonisolated static func liveWorkspaceNames() -> [String: String] {
        let root = Constants.databasePath
        var names: [String: String] = [:]
        for name in Constants.workspacesWithDatabase(under: root) {
            names[SessionHostPaths.scope(databasePath: "\(root)/\(name)/watchtower.db")] = name
        }
        return names
    }
}

enum HostRestartError: Error {
    case noWorkbenches
}
