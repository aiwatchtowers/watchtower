import AppKit
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Native-push seam for the session notices (the `WorkbenchNotifying`
/// shape), so the center is testable without `UNUserNotificationCenter`.
protocol SessionAgentNotifying {
    func sendSessionAgentNotice(_ notice: SessionAgentNoticePolicy.Notice)
    func withdrawSessionAgentNotice(identifier: String)
    func withdrawAllSessionAgentNotices()
}

extension NotificationService: SessionAgentNotifying {}

/// What each live Claude Code session's agent is doing — working, waiting
/// for the owner, needing approval — as its workbench hooks write it to
/// `terminal_sessions` (board #312, spec 2026-10-03-session-agent-state
/// decision 10). The hooks run in another process, so GRDB observation never
/// fires: a 1 s poll, and only while at least one `claude` session runs here
/// (it follows `TerminalCenter.liveClaudeIDs`). Owned by `AppState`, so it
/// keeps going with the Workbench tab or the window closed. Never writes:
/// Go is the only writer of those columns. Each change feeds
/// `SessionAgentNoticePolicy`: a session turning to the owner is announced
/// while the app is in the background (decision 12).
@MainActor
@Observable
final class SessionAgentStateCenter {
    static let pollInterval: Duration = .seconds(1)

    /// Keyed by `terminal_sessions.id`; live `claude` sessions only.
    private(set) var statuses: [Int64: SessionAgentStatus] = [:]

    /// The poll's DB read, seamed so a test can count or fail it.
    typealias Reader = @Sendable ([Int64]) async throws -> [SessionAgentStateRow]

    @ObservationIgnored private let terminalCenter: TerminalCenter
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let notifier: SessionAgentNotifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var notices = SessionAgentNoticePolicy()
    /// Whether the app is frontmost, when a banner is not needed. Without an
    /// application object (a test host) nothing is posted.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp?.isActive ?? true }
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var following = false
    /// A read error is logged once per streak of failures.
    @ObservationIgnored private var failing = false

    init(
        dbPool: DatabasePool,
        terminalCenter: TerminalCenter,
        interval: Duration = SessionAgentStateCenter.pollInterval,
        notifier: SessionAgentNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard,
        read: Reader? = nil
    ) {
        self.terminalCenter = terminalCenter
        self.interval = interval
        self.notifier = notifier
        self.defaults = defaults
        self.read = read ?? { ids in
            try await dbPool.read { try TerminalSessionQueries.fetchAgentStates($0, ids: ids) }
        }
    }

    /// Whether the 1 s loop is running (a test seam).
    var isPolling: Bool { pollTask != nil }

    /// Follows the terminal center's live `claude` sessions from now on.
    /// Banners a previous process left are removed: no session runs yet.
    func start() {
        guard !following else { return }
        following = true
        notifier.withdrawAllSessionAgentNotices()
        followLiveness()
    }

    /// The app quits: every session stops with it, and so do their banners.
    func withdrawAllNotices() {
        notifier.withdrawAllSessionAgentNotices()
    }

    func stop() {
        following = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// One read of the live sessions' stored states. Nothing is read when no
    /// `claude` session is live.
    func poll() async {
        let ids = terminalCenter.liveClaudeIDs
        guard !ids.isEmpty else {
            publish([:])
            return
        }
        do {
            let rows = try await read(ids.sorted())
            failing = false
            publish(SessionAgentStatus.resolve(
                rows, liveIDs: terminalCenter.liveClaudeIDs, startedAt: terminalCenter.startedAt
            ))
        } catch {
            if !failing {
                print("[SessionAgentState] read error: \(error.localizedDescription)")
                failing = true
            }
            // The last map stays, minus the sessions that stopped meanwhile.
            let live = terminalCenter.liveClaudeIDs
            publish(statuses.filter { live.contains($0.key) })
        }
    }

    /// Assigned only on a change, so an unchanged poll re-renders nothing;
    /// the change is what the notice policy decides on.
    private func publish(_ next: [Int64: SessionAgentStatus]) {
        guard next != statuses else { return }
        statuses = next
        let canPost = !isAppActive() && WorkbenchNotificationCenter.sending(defaults)
        for action in notices.update(next, canPost: canPost) {
            switch action {
            case let .post(notice): notifier.sendSessionAgentNotice(notice)
            case let .withdraw(identifier): notifier.withdrawSessionAgentNotice(identifier: identifier)
            }
        }
    }

    /// Starts the loop while a `claude` session is live and ends it when the
    /// last one stops, re-armed on every change of the live set.
    private func followLiveness() {
        guard following else { return }
        let live = withObservationTracking {
            terminalCenter.liveClaudeIDs
        } onChange: { [weak self] in
            Task { @MainActor in self?.followLiveness() }
        }
        if live.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            publish([:])
        } else if pollTask == nil {
            pollTask = Task { [weak self, interval] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }
}
