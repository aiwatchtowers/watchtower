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

/// What each workbench Claude Code session's agent is doing — working,
/// stopped, needing approval, finished, waiting on an ask — as its workbench
/// hooks and tools write it to `terminal_sessions` (board #312, spec
/// 2026-10-03-session-agent-state decision 10; the states of spec
/// 2026-10-03-workbench-session-report §4b). Every workbench `claude` row is
/// read, live or not, plus the live standalone ones. The writes come from
/// another process, so GRDB observation never fires: a 1 s poll, only while
/// at least one `claude` session runs here (it follows
/// `TerminalCenter.liveClaudeIDs`), and one read on app activation, when the
/// Workbench tab appears and right after an ask is answered — a session that
/// is not live changes in no other way. Owned by `AppState`, so it keeps
/// going with the Workbench tab or the window closed. Never writes: Go is the
/// only writer of those columns. Each change feeds `SessionAgentNoticePolicy`:
/// a session turning to the owner is announced while the app is in the
/// background (decision 12).
@MainActor
@Observable
final class SessionAgentStateCenter {
    nonisolated static let pollInterval: Duration = .seconds(1)

    /// Keyed by `terminal_sessions.id`: every workbench `claude` session,
    /// live or not, and the live standalone `claude` terminals.
    private(set) var statuses: [Int64: SessionAgentStatus] = [:]

    /// The DB read, given the live `claude` ids; seamed so a test can count
    /// or fail it.
    typealias Reader = @Sendable ([Int64]) async throws -> [SessionAgentStateRow]

    @ObservationIgnored private let terminalCenter: TerminalCenter
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let notifier: SessionAgentNotifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var notices = SessionAgentNoticePolicy()
    /// Whether the app is frontmost, when a banner is not needed. Without an
    /// application object (a test host) nothing is posted.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp?.isActive ?? true }
    /// Every change of `statuses`, after it is assigned (held ask answers
    /// go once their session leaves a permission prompt). One subscriber.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var following = false
    /// The last good read, resolved again whenever liveness changes.
    @ObservationIgnored private var rows: [SessionAgentStateRow] = []
    /// Reads overlap (the poll, a refresh): only one started after the last
    /// applied read is applied, so a slow older read never undoes a newer one.
    @ObservationIgnored private var readsStarted = 0
    @ObservationIgnored private var readApplied = 0
    /// A read error is logged once per streak of failures.
    @ObservationIgnored private var failing = false

    init(
        dbPool: DatabasePool,
        terminalCenter: TerminalCenter,
        interval: Duration = SessionAgentStateCenter.pollInterval,
        notifier: SessionAgentNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        read: Reader? = nil
    ) {
        self.terminalCenter = terminalCenter
        self.interval = interval
        self.notifier = notifier
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.read = read ?? { ids in
            try await dbPool.read { try TerminalSessionQueries.fetchAgentStates($0, liveIDs: ids) }
        }
    }

    /// Whether the 1 s loop is running (a test seam).
    var isPolling: Bool { pollTask != nil }

    /// Follows the terminal center's live `claude` sessions and app
    /// activation from now on. Banners a previous process left are removed:
    /// no session runs yet.
    func start() {
        guard !following else { return }
        following = true
        notifier.withdrawAllSessionAgentNotices()
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
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
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// One read now, live session or not: the Workbench tab appeared, or an
    /// ask was answered.
    func refresh() {
        Task { await poll() }
    }

    /// One read of the stored states.
    func poll() async {
        readsStarted += 1
        let token = readsStarted
        do {
            let next = try await read(terminalCenter.liveClaudeIDs.sorted())
            failing = false
            guard token > readApplied else { return }
            readApplied = token
            rows = next
        } catch {
            if !failing {
                print("[SessionAgentState] read error: \(error.localizedDescription)")
                failing = true
            }
            // The last good read stays, resolved for the sessions live now.
        }
        publishResolved()
    }

    /// The last good read under the current liveness and run starts: a
    /// session that stopped or started again loses its previous run's hook
    /// state at once, not a read later.
    private func publishResolved() {
        publish(SessionAgentStatus.resolve(
            rows, liveIDs: terminalCenter.liveClaudeIDs, startedAt: terminalCenter.startedAt
        ))
    }

    /// Assigned only on a change, so an unchanged read re-renders nothing;
    /// the change is what the notice policy decides on.
    private func publish(_ next: [Int64: SessionAgentStatus]) {
        guard next != statuses else { return }
        statuses = next
        onChange?()
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
        // A Restart never shows the previous run's state while other
        // sessions keep the loop going, and an exit turns the dot into a
        // ring without waiting for a read.
        publishResolved()
        if live.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        if pollTask == nil {
            pollTask = Task { [weak self, interval] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }
}
