import Foundation
import os
import WatchtowerCore
import WatchtowerSync

/// Runs `watchtower workbench session-feed --session S --json` for the
/// `session_chat` slice, only for the sessions (or subagents) the phone
/// watches: a `session_chat_request` opens a watch of `Timing.watch` (5 min)
/// from the last request, and the phone repeats the request while its Chat
/// screen is open. Per watch:
/// - one run when the watch opens;
/// - every `Timing.every` (10 s) while the session is live;
/// - once more after the session stopped being live, to publish the end of
///   its chat; a finished session otherwise runs once per watch.
///
/// The capped payloads (`SessionChatPayload`) live in memory only: a watch
/// does not survive a restart anyway, and nothing transcript-derived is
/// written to disk on the Mac. An expired watch loses its payload, so the
/// record leaves the phone. A failed, undecodable or hung run keeps the last
/// payload and the next run is scheduled as usual. It never touches the relay
/// processor.
final class SessionChatRunner: HubCompanion, Sendable {
    typealias Fetch = @Sendable (_ sessionID: Int64, _ agentID: String?) async throws -> SessionFeedPayload
    typealias IsLive = @Sendable (Int64) -> Bool

    struct Timing: Equatable, Sendable {
        /// The regular run of a live session.
        let every: Duration
        /// How long a request keeps a session watched.
        let watch: Duration
        /// The bound on one CLI run.
        let timeout: Duration
        /// How often the loop looks for due watches.
        let wake: Duration

        static let standard = Self(every: .seconds(10), watch: .seconds(300), timeout: .seconds(30), wake: .seconds(2))
    }

    struct Key: Hashable, Sendable {
        let sessionID: Int64
        let agentID: String?

        /// The slice record id (`SessionChat.recordName` of the Kit mirror
        /// is `session_chat-<id>`).
        var id: String { agentID.map { "\(sessionID)-\($0)" } ?? String(sessionID) }
    }

    struct Watch {
        var expires: ContinuousClock.Instant
        var lastAttempt: ContinuousClock.Instant?
        var payload: Data?
        var fetchedAt: Date?
        /// The `live` flag the stored payload was encoded with.
        var storedLive = false
    }

    /// One watched feed with a payload, as the slice publishes it.
    struct Snapshot: Equatable {
        let id: String
        let payload: Data
        let fetchedAt: Date
    }

    let fetch: Fetch
    let isLive: IsLive
    let timing: Timing
    let clock: @Sendable () -> ContinuousClock.Instant
    let now: @Sendable () -> Date
    /// Whether a pass runs at all (the hub's linked-phone gate).
    private let isActive: @Sendable () -> Bool
    let watches = OSAllocatedUnfairLock(initialState: [Key: Watch]())
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: Constants.bundleID, category: "SessionChatRunner")

    init(
        fetch: @escaping Fetch,
        isLive: @escaping IsLive,
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        now: @escaping @Sendable () -> Date = { Date() },
        isActive: @escaping @Sendable () -> Bool = { true }
    ) {
        self.fetch = fetch
        self.isLive = isLive
        self.timing = timing
        self.clock = clock
        self.now = now
        self.isActive = isActive
    }

    /// The `SessionFeedStore` argv of a full read, plus `--subagent` for a
    /// subagent's feed.
    static func arguments(sessionID: Int64, agentID: String?) -> [String] {
        let args = ["workbench", "session-feed", "--session", String(sessionID), "--json"]
        return agentID.map { args + ["--subagent", $0] } ?? args
    }

    /// The hub's runner: the CLI through `runner`; no pass runs while
    /// `isActive` is false.
    static func live(
        _ runner: any CLIRunnerProtocol,
        isLive: @escaping IsLive,
        isActive: @escaping @Sendable () -> Bool = { true }
    ) -> SessionChatRunner {
        SessionChatRunner(fetch: cliFetch(runner), isLive: isLive, isActive: isActive)
    }

    /// The CLI run and its decode, as `SessionFeedStore`. It relies on full
    /// (cursor-less) reads: every run returns the whole feed, so the subagent
    /// markers already carry their current status and need no overlay.
    static func cliFetch(_ runner: any CLIRunnerProtocol) -> Fetch {
        { sessionID, agentID in
            let data = try await runner.run(args: arguments(sessionID: sessionID, agentID: agentID))
            return try JSONDecoder().decode(SessionFeedPayload.self, from: data)
        }
    }

    /// The phone's `session_chat_request`: opens or extends the watch of the
    /// session's chat (or one subagent's).
    func request(sessionID: Int64, agentID: String?) {
        let expires = clock() + timing.watch
        watches.withLock { watches in
            watches[Key(sessionID: sessionID, agentID: agentID), default: Watch(expires: expires)].expires = expires
        }
    }

    /// The payloads of the unexpired watches that have one, keyed by record
    /// name. Expired watches are dropped here.
    func payloads() -> [String: Data] {
        Dictionary(uniqueKeysWithValues: snapshots().map { (SliceKind.sessionChat.recordName(id: $0.id), $0.payload) })
    }

    func snapshots() -> [Snapshot] {
        let stamp = clock()
        return watches.withLock { watches in
            watches = watches.filter { $0.value.expires > stamp }
            return watches.compactMap { key, watch in
                guard let payload = watch.payload, let fetchedAt = watch.fetchedAt else { return nil }
                return Snapshot(id: key.id, payload: payload, fetchedAt: fetchedAt)
            }
        }
    }

    // MARK: - Pass

    /// One pass: drops the expired watches, then runs the due ones one after
    /// the other. A `stop()` during the pass ends it before its next run;
    /// the run in flight stores nothing.
    /// - Returns: the watches whose CLI run was started, in order.
    @discardableResult
    func runDue() async -> [Key] {
        let passGeneration = generation.withLock { $0 }
        var attempted: [Key] = []
        for key in takeDue() {
            guard !Task.isCancelled, isCurrent(passGeneration) else { break }
            attempted.append(key)
            await run(key, passGeneration: passGeneration)
        }
        return attempted
    }

    private func isCurrent(_ passGeneration: Int) -> Bool {
        generation.withLock { $0 == passGeneration }
    }

    /// Drops the expired watches and stamps the due ones as attempted now.
    private func takeDue() -> [Key] {
        let stamp = clock()
        return watches.withLock { [timing, isLive] watches in
            watches = watches.filter { $0.value.expires > stamp }
            var due: [Key] = []
            for (key, var watch) in watches {
                let live = isLive(key.sessionID)
                let isDue: Bool = {
                    guard let last = watch.lastAttempt else { return true }
                    guard stamp - last >= timing.every else { return false }
                    return live || watch.payload == nil || watch.storedLive
                }()
                guard isDue else { continue }
                watch.lastAttempt = stamp
                watches[key] = watch
                due.append(key)
            }
            return due.sorted { ($0.sessionID, $0.agentID ?? "") < ($1.sessionID, $1.agentID ?? "") }
        }
    }

    private func run(_ key: Key, passGeneration: Int) async {
        let fetch = self.fetch
        let result = await MobileHubService.bounded(timing.timeout) { () -> Result<SessionFeedPayload, any Error> in
            do {
                return .success(try await fetch(key.sessionID, key.agentID))
            } catch {
                return .failure(error)
            }
        }
        guard isCurrent(passGeneration) else { return }
        let id = key.id
        switch result {
        case nil:
            logger.warning("session chat \(id, privacy: .public) timed out; keeping the last payload")
        case .failure(let error)?:
            logger.warning("session chat \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        case .success(let feed)?:
            let (live, stamp) = (isLive(key.sessionID), now())
            do {
                let payload = try SessionChatPayload.encode(feed, sessionID: key.sessionID, agentID: key.agentID, live: live, now: stamp)
                watches.withLock { watches in
                    // A watch that expired or was dropped meanwhile stays gone.
                    guard var watch = watches[key] else { return }
                    watch.payload = payload
                    watch.fetchedAt = stamp
                    watch.storedLive = live
                    watches[key] = watch
                }
            } catch {
                logger.error("encoding the session chat \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - HubCompanion

    func start() {
        generation.withLock { $0 += 1 }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isActive() { await self.runDue() }
                try? await Task.sleep(for: self.timing.wake)
            }
        }
        loopTask.withLock { current in
            current?.cancel()
            current = task
        }
    }

    func stop() {
        generation.withLock { $0 += 1 }
        loopTask.withLock { current in
            current?.cancel()
            current = nil
        }
        // Nothing transcript-derived outlives the hub.
        watches.withLock { $0.removeAll() }
    }
}
