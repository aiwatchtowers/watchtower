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

    /// The outcome's kind for the log: no reason text (FILES-01).
    var logKind: String {
        switch self {
        case .launched: "launched"
        case .noConversation: "no_conversation"
        case .failed: "failed"
        case .rowGone: "row_gone"
        }
    }
}

/// The one-time restart of live sessions from a v1 session host into a v2
/// one (go hub spec §8 p. 4b, asks #813, #814 — a one-time PROJ-20
/// exception). The app update leaves the old host running with the old
/// app's sessions; the Go hub never talks to it. At launch, after the
/// reattach, `runIfNeeded` looks at the host:
///
/// 0. a v1 host with live runs and no restart list: the notice waits for
///    **Continue** (`waitingForContinue`). Nothing else happens until it is
///    pressed; a quit leaves the old host and its sessions, and the notice
///    comes back next launch.
/// 1. Continue: the runs of every scope are listed as a v1 client and
///    written to the restart list (`HostRestartList`) before anything is
///    touched;
/// 2. each run is stopped as Stop Sessions stops it — dropped from the
///    terminal center first, then signalled (`TerminalCenter
///    .stopForHostRestart`), so no PROJ-18 cleanup runs — and forgotten;
///    the idle old host gets SIGTERM (pid from its HelloOK) and a v2 host is
///    started through the usual ensure path;
/// 3. this workspace's listed rows relaunch with resume, each removed from
///    the list once launched. Other workspaces' rows wait in the list for
///    that workspace's launch, which runs step 3 for them
///    (`waitingWorkspaces` feeds the "N sessions wait to resume" line).
///
/// A list left by an interrupted run is picked up at the next launch with
/// no notice (Continue was pressed): a v1 host still up is handled from
/// step 1, rows already relaunched are not in the list any more. Main actor.
@MainActor
@Observable
final class HostRestartStep {
    enum Phase: Equatable {
        case notNeeded
        case waitingForContinue
        case stopping(done: Int, total: Int)
        case relaunching(done: Int, total: Int)
        case finished
        case failed(String)
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
    }

    // MARK: Copy (pinned by `HostRestartStepTests.testCopyIsInTheModel`)

    nonisolated static let noticeText = "Running sessions restart once with this update; their conversations continue"
    nonisolated static let continueTitle = "Continue"
    nonisolated static let retryTitle = "Retry"
    nonisolated static let failedTitle = "Sessions could not be restarted"
    nonisolated static let readFailed = "Watchtower could not read the running sessions. Your sessions were not changed."
    nonisolated static let saveFailed = "Watchtower could not save the list of running sessions. Your sessions were not changed."
    nonisolated static let oldHostKept = "The old session host did not stop. Your sessions resume on Retry."
    nonisolated static let hostDidNotStart = "The session host did not start. Your sessions resume on Retry."
    nonisolated static let workbenchesNotReady = "The workbenches are not loaded. Your sessions resume on Retry."

    nonisolated static func waitLine(_ count: Int) -> String {
        count == 1 ? "1 session waits to resume" : "\(count) sessions wait to resume"
    }

    nonisolated static func stoppingLine(done: Int, total: Int) -> String {
        "Stopping sessions… \(done) of \(total)"
    }

    nonisolated static func relaunchingLine(done: Int, total: Int) -> String {
        "Resuming sessions… \(done) of \(total)"
    }

    nonisolated static func notice(for phase: Phase) -> Notice? {
        switch phase {
        case .notNeeded, .finished:
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
        }
    }

    nonisolated private static func fraction(_ done: Int, _ total: Int) -> Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    // MARK: State

    private(set) var phase: Phase = .notNeeded
    private(set) var waitingWorkspaces: [WaitingWorkspace] = []
    var notice: Notice? { Self.notice(for: phase) }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "HostRestart")
    /// How long the old host gets to exit after SIGTERM, and the poll step.
    static let hostExitWait: Duration = .seconds(5)
    static let hostExitPoll: Duration = .milliseconds(100)

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

    /// The launch's look at the session host, once the reattach is done
    /// (see the type). Returns once the notice waits, or the work it could
    /// do without the owner is done.
    func runIfNeeded() async {
        guard !working else { return }
        working = true
        defer { working = false; refreshWaiting() }
        await workbenches()?.hostReattach?.value
        let list = loadList()
        let mine = list?.rows(in: center.sessionHostScope) ?? []
        guard let client = await center.connectedSessionHost() else {
            phase = mine.isEmpty ? .notNeeded : .failed(Self.hostDidNotStart)
            return
        }
        if client.speaksV2 {
            if mine.isEmpty { phase = .notNeeded } else { await relaunch(list ?? HostRestartList()) }
            return
        }
        // A v1 host. A list on disk means Continue was pressed already.
        if list != nil {
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

    /// The notice's Continue, and Retry after a failure.
    func pressContinue() async {
        switch phase {
        case .waitingForContinue, .failed: break
        default: return
        }
        guard !working else { return }
        working = true
        defer { working = false; refreshWaiting() }
        guard let client = await center.connectedSessionHost() else {
            phase = .failed(Self.hostDidNotStart)
            return
        }
        if client.speaksV2 {
            await relaunch(loadList() ?? HostRestartList())
        } else {
            await restart(client)
        }
    }

    // MARK: Steps

    /// Steps 1–3 against a v1 host.
    private func restart(_ client: SessionHostClient) async {
        // Step 1: list every scope's runs and write them down first.
        let runs: [SessionHostSessionInfo]
        var list: HostRestartList
        do {
            runs = try await client.list()
            let mine = try await thisScopesRows(runs)
            list = listRows(of: runs, into: loadList() ?? HostRestartList(), rows: mine)
        } catch {
            Self.logger.error("v1 host restart, list: \(String(describing: error), privacy: .private)")
            phase = .failed(Self.readFailed)
            return
        }
        do {
            try list.save(to: listURL)
        } catch {
            Self.logger.error("v1 host restart, save: \(error.localizedDescription, privacy: .private)")
            phase = .failed(Self.saveFailed)
            return
        }
        let hostPID = client.hostPID
        // Step 2: stop every run at once (one grace, not N), then the host.
        let total = runs.count
        phase = .stopping(done: 0, total: total)
        await withTaskGroup(of: Void.self) { group in
            for info in runs {
                group.addTask { @MainActor in await self.center.stopForHostRestart(info) }
            }
            var done = 0
            for await _ in group {
                done += 1
                phase = .stopping(done: done, total: total)
            }
        }
        if let pid = hostPID.map(pid_t.init), pid > 0 {
            signalHost(pid, SIGTERM)
            var waited: Duration = .zero
            while hostIsAlive(pid), waited < Self.hostExitWait {
                await sleep(Self.hostExitPoll)
                waited += Self.hostExitPoll
            }
            if hostIsAlive(pid) {
                phase = .failed(Self.oldHostKept)
                return
            }
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
        // Step 3.
        await relaunch(list)
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

    /// Step 3: this workspace's listed rows, one at a time, each removed
    /// from the list once its launch ran — whatever it ended in.
    private func relaunch(_ start: HostRestartList) async {
        guard let vm = workbenches() else {
            phase = .failed(Self.workbenchesNotReady)
            return
        }
        var list = start
        let mine = list.rows(in: center.sessionHostScope)
        phase = .relaunching(done: 0, total: mine.count)
        for (index, row) in mine.enumerated() {
            let outcome = await vm.relaunchAfterHostRestart(rowID: row.rowID)
            if outcome != .launched {
                Self.logger.info("v1 host restart: row \(row.rowID) \(outcome.logKind, privacy: .public)")
            }
            list.remove(scope: row.scope, rowID: row.rowID)
            do {
                try list.save(to: listURL)
            } catch {
                // The next launch finds the row running and skips it.
                Self.logger.error("v1 host restart, save: \(error.localizedDescription, privacy: .private)")
            }
            phase = .relaunching(done: index + 1, total: mine.count)
        }
        phase = .finished
    }

    // MARK: The list

    private func loadList() -> HostRestartList? {
        do {
            return try HostRestartList.load(from: listURL)
        } catch {
            Self.logger.error("restart list unreadable: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Recomputes the other workspaces' wait lines from the list on disk.
    func refreshWaiting() {
        let counts = loadList()?.waiting(besides: center.sessionHostScope) ?? [:]
        guard !counts.isEmpty else {
            waitingWorkspaces = []
            return
        }
        let names = workspaceNames()
        let found = counts.compactMap { scope, count in
            names[scope].map { WaitingWorkspace(name: $0, count: count) }
        }
        waitingWorkspaces = found.sorted { $0.name < $1.name }
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
