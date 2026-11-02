import Foundation
import GRDB
import WatchtowerCore

/// "Keep this Mac awake for the iPhone" with the Go hub (go hub plan 3
/// Task 23, ask #614): the Swift hub's `KeepAwakeCompanion` rule, now taken
/// by Desktop, which owns the setting and the app's lifetime. Every 30 s it
/// holds the "prevent idle system sleep" assertion while the hub runs, the
/// owner's switch is on, a board session runs and a phone was in touch in
/// the last 24 hours (`KeepAwakePolicy`); the hub's heartbeat answer says
/// when a phone last was (`HubCenter.lastPhoneContact`). `stop()` (a quit or
/// a rebuilt hub center) drops the assertion.
@MainActor
final class HubKeepAwake {
    nonisolated static let interval: Duration = .seconds(30)

    struct Inputs {
        /// The owner's switch (`Constants.mobileKeepAwakeKey`, on unless turned off).
        let enabled: @MainActor () -> Bool
        /// The hub runs (`hub status` state `running`).
        let hubRunning: @MainActor () -> Bool
        /// The workbenches with a live agent session.
        let liveBoardSessions: @MainActor () -> Int
        /// When a phone was last in touch (nil = never, or no hub answers).
        let lastPhoneContact: @MainActor () -> Date?
    }

    private let assertion: MacAwakeAssertion
    private let inputs: Inputs
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private var loop: Task<Void, Never>?

    init(
        assertion: MacAwakeAssertion? = nil,
        inputs: Inputs,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.assertion = assertion ?? MacAwakeAssertion()
        self.inputs = inputs
        self.now = now
        self.sleep = sleep
    }

    var isHolding: Bool { assertion.isHolding }

    /// One look: hold or release.
    func evaluate() {
        let hold = inputs.hubRunning() && KeepAwakePolicy.shouldHold(
            enabled: inputs.enabled(), liveBoardSessions: inputs.liveBoardSessions(),
            lastPhoneContact: inputs.lastPhoneContact(), now: now()
        )
        assertion.update(hold: hold)
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self, sleep] in
            while !Task.isCancelled {
                self?.evaluate()
                await sleep(Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        assertion.update(hold: false)
    }

    /// The workbenches with a live agent session among `liveIDs` (plain
    /// shells never count); 0 when the read fails, so the Mac is not held
    /// awake on an unknown count.
    nonisolated static func liveBoardSessions(_ pool: DatabasePool?, liveIDs: Set<Int64>) -> Int {
        guard let pool, !liveIDs.isEmpty else { return 0 }
        let ids = Array(liveIDs)
        do {
            return try pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(DISTINCT project_id) FROM terminal_sessions
                        WHERE kind IN \(AgentKind.sqlKinds) AND project_id IS NOT NULL
                          AND id IN (\(databaseQuestionMarks(count: ids.count)))
                        """,
                    arguments: StatementArguments(ids)
                ) ?? 0
            }
        } catch {
            keepAwakeLogger.error("live board sessions unreadable: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
