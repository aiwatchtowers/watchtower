import Foundation
import GRDB
import Observation
import OSLog
import WatchtowerCore

private let sessionsLog = Logger(subsystem: Constants.bundleID, category: "automation-sessions")

/// Launches the sessions automation runs ask for through `session()` (spec
/// §13.1) and tells Go how each one went. Owned by `AppState` so a launch
/// finishes whatever page the owner is on; it polls every 3 s while the
/// `automations` feature is on (ruling R-P5-8) — the daemon writes the
/// requests from another process, so GRDB observation never fires.
///
/// - A request is launched once (`launching`) and attached with
///   `session-launched` (the CLI wakes the daemon). A row of the run that no
///   step names — the app went away between creating and attaching it — is
///   adopted instead of launching a second session.
/// - A launch that throws is reported `launch_failed` with its message; the
///   row it may have left loses the run marker, so no later poll adopts it.
/// - `attached: false` (the run was cancelled or expired meanwhile) leaves
///   the session as it is (§7.6).
/// - A session whose process ends while its step waits, unfinished, is
///   reported `stopped` (R-P5-3); `start()` reconciles the ones that ended
///   while the app or the feature was off. A stopped center reports nothing:
///   quitting closes every terminal, and the next start reconciles those.
@MainActor
@Observable
final class AutomationSessionCenter {
    static let pollInterval: Duration = .seconds(3)

    /// Steps whose session is being launched or attached right now.
    private(set) var launching: Set<Int64> = []
    /// The last read, launch or report that failed; nil again after a poll
    /// whose read went through.
    private(set) var lastError: String?

    /// Logs a step whose args cannot be read; once per step (a seam).
    @ObservationIgnored var logUnreadable: (Int64) -> Void = { step in
        sessionsLog.error("session step \(step) has unreadable args, not launched")
    }

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let startSession: (PendingSessionRequest) async throws -> TerminalSession
    @ObservationIgnored private let isLive: (Int64) -> Bool
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Launches that failed, by step, with their message: reported again
    /// until a report goes through, never adopted or relaunched.
    @ObservationIgnored private var failedLaunches: [Int64: String] = [:]
    /// Steps whose attach Go refused: their run no longer waits.
    @ObservationIgnored private var refused: Set<Int64> = []
    @ObservationIgnored private var loggedUnreadable: Set<Int64> = []

    init(
        dbPool: DatabasePool,
        cli: AutomationsCLI,
        start: @escaping (PendingSessionRequest) async throws -> TerminalSession,
        isLive: @escaping (Int64) -> Bool,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.startSession = start
        self.isLive = isLive
        self.sleep = sleep
    }

    var isRunning: Bool { loop != nil }

    /// Reconciles, then polls until `stop()`. A second call keeps the loop.
    func start() {
        guard loop == nil else { return }
        let sleep = sleep
        loop = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.reconcile()
            while !Task.isCancelled, let center = self {
                await center.tick()
                await sleep(Self.pollInterval)
            }
        }
    }

    /// Stops polling. A launch in flight still finishes and attaches.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One poll: every pending request not already in hand, each in its own
    /// task; returns when this poll's launches are done.
    func tick() async {
        let pending: [PendingSessionRequest]
        do {
            let fetched = try await dbPool.read { try AutomationQueries.fetchPendingSessionRequests($0) }
            for step in fetched.unreadable where !loggedUnreadable.contains(step) {
                loggedUnreadable.insert(step)
                logUnreadable(step)
            }
            pending = fetched.requests.filter { !launching.contains($0.stepID) && !refused.contains($0.stepID) }
            lastError = nil
        } catch {
            fail("reading the requested sessions", error)
            return
        }
        launching.formUnion(pending.map(\.stepID))
        await withTaskGroup(of: Void.self) { group in
            for request in pending {
                group.addTask { @MainActor in
                    await self.handle(request)
                    self.launching.remove(request.stepID)
                }
            }
        }
    }

    /// Session `rowID`'s process ended: its step, still waiting on it
    /// unfinished, is reported stopped.
    func sessionExited(rowID: Int64) async {
        guard isRunning else { return }
        await reportStopped { $0 == rowID }
    }

    // MARK: - Private

    private func handle(_ request: PendingSessionRequest) async {
        if let message = failedLaunches[request.stepID] {
            await reportLaunchFailed(request, message)
            return
        }
        let session: TerminalSession
        do {
            let runID = request.runID
            if let orphan = try await dbPool.read({ try AutomationQueries.unattachedSession($0, runID: runID) }) {
                session = orphan
            } else {
                do {
                    session = try await startSession(request)
                } catch {
                    failedLaunches[request.stepID] = error.localizedDescription
                    await disown(runID: runID)
                    await reportLaunchFailed(request, error.localizedDescription)
                    return
                }
            }
        } catch {
            fail("reading run \(request.runID)'s sessions", error)
            return
        }
        do {
            guard try await cli.sessionLaunched(step: request.stepID, session: session.id) else {
                refused.insert(request.stepID)
                return
            }
            // An adopted row whose process is gone: nothing else reports it.
            if !isLive(session.id) {
                _ = try await cli.sessionEnded(step: request.stepID, status: .stopped, error: nil)
            }
        } catch {
            fail("attaching session \(session.id) to step \(request.stepID)", error)
        }
    }

    private func reportLaunchFailed(_ request: PendingSessionRequest, _ message: String) async {
        do {
            _ = try await cli.sessionEnded(step: request.stepID, status: .launchFailed, error: message)
            failedLaunches[request.stepID] = nil
        } catch {
            fail("reporting step \(request.stepID)'s failed launch", error)
        }
    }

    /// The refused launch's row stays in SESSIONS but is no longer the run's.
    private func disown(runID: Int64) async {
        do {
            try await dbPool.write { try AutomationQueries.disownUnattachedSessions($0, runID: runID) }
        } catch {
            fail("releasing run \(runID)'s refused session", error)
        }
    }

    /// App launch (or the feature back on): every waiting step whose
    /// session is not running is reported stopped.
    private func reconcile() async {
        await reportStopped { [isLive] in !isLive($0) }
    }

    private func reportStopped(where matches: (Int64) -> Bool) async {
        let steps: [(stepID: Int64, sessionID: Int64)]
        do {
            steps = try await dbPool.read { try AutomationQueries.waitingSessionSteps($0) }
        } catch {
            fail("reading the sessions automation runs wait on", error)
            return
        }
        for step in steps where matches(step.sessionID) {
            do {
                _ = try await cli.sessionEnded(step: step.stepID, status: .stopped, error: nil)
            } catch {
                fail("reporting session \(step.sessionID) stopped", error)
            }
        }
    }

    private func fail(_ what: String, _ error: Error) {
        let message = "\(what): \(error.localizedDescription)"
        sessionsLog.error("\(message, privacy: .public)")
        lastError = message
    }
}
