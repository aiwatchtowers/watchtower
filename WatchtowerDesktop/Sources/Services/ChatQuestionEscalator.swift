import Foundation
import WatchtowerCore

/// Raises a recorded Chat question into an owner ask when
/// `ChatQuestionEscalationPolicy` says so (spec 2026-10-10-owner-asks-v2
/// Part 5.2), by running `watchtower workbench escalate-question` — Go is
/// the only writer and files only while the question is still the stored
/// one (compare-and-take, Part 5.3). Owned by `AppState`, started with the
/// workbenches; modelled on `SessionBackgroundProber`.
///
/// - Nothing is evaluated before the owner's presence has settled once: an
///   unknown presence at launch must not read as away (E22a).
/// - Evaluates on every agent-state resolve, every presence change and a
///   30 s tick while any live session holds a question; at most one run in
///   flight per session.
/// - A transient failure (`busy`, `open_cap`) is tried again at the next
///   evaluation at most once a minute per session; any other failure, and
///   `gone`, stop the runs for that question (`chat_question_at`) — a new
///   question starts fresh. A `filed` ask asks the asks poll for a read.
/// - A failure and an unreadable stamp are logged once per question.
/// - `stop()` cancels every run in flight: the runner terminates its child
///   and waits for it (`ProcessCLIRunner`); the Go command starts no
///   children of its own.
///
/// Every bookkeeping entry is in memory only.
@MainActor
final class ChatQuestionEscalator {
    /// How soon a transient failure is tried again.
    nonisolated static let retryAfter: TimeInterval = 60
    /// The evaluation tick while any session holds a question.
    nonisolated static let tickInterval: TimeInterval = 30

    /// What the agent-state center last resolved: the stored rows and the
    /// run rules they are judged under.
    struct Sessions {
        var rows: [SessionAgentStateRow]
        var liveIDs: Set<Int64>
        var startedAt: [Int64: Date]

        static let empty = Self(rows: [], liveIDs: [], startedAt: [:])
    }

    /// Runs `fire` once after `seconds` on the main actor; the returned
    /// closure cancels it (`OwnerPresenceCenter.Schedule`).
    typealias Schedule = OwnerPresenceCenter.Schedule

    /// The rows to evaluate.
    var sessions: () -> Sessions = { .empty }
    /// Where the owner is relative to a session; nil until presence has
    /// settled.
    var presence: (_ sessionID: Int64) -> ChatQuestionEscalationPolicy.Presence? = { _ in nil }
    /// Whether the owner has unsent text in the session's prompt.
    var hasOwnerDraft: (_ sessionID: Int64) -> Bool = { _ in false }
    /// An ask was filed in the workbench. One subscriber.
    var onFiled: ((_ projectID: Int64) -> Void)?
    /// Where the log lines go; seamed so a test counts them.
    var log: (String) -> Void = { print($0) }

    /// The runs of one question of one session.
    private struct Entry {
        /// The question's `chat_question_at`, raw.
        let at: String
        /// When its last run started.
        var lastRun: Date
        /// `filed`, `gone` or a non-transient failure: no more runs.
        var stopped = false
        /// A failure of this question was logged.
        var logged = false
    }

    private let cli: WorkbenchCLI
    private let clock: () -> Date
    private let schedule: Schedule
    /// Keyed by `terminal_sessions.id`.
    private var entries: [Int64: Entry] = [:]
    /// The `chat_question_at` whose unreadable stamp was logged, per session.
    private var unreadableLogged: [Int64: String] = [:]
    /// The run in flight per session, with its token: a run `stop()`
    /// cancelled never clears a later one.
    private var inFlight: [Int64: (token: Int, task: Task<Void, Never>)] = [:]
    private var runsStarted = 0
    private var running = false
    private var cancelTick: (() -> Void)?

    init(runner: any CLIRunnerProtocol, clock: @escaping () -> Date = { Date() }, schedule: Schedule? = nil) {
        cli = WorkbenchCLI(runner: runner)
        self.clock = clock
        self.schedule = schedule ?? OwnerPresenceCenter.liveSchedule
    }

    /// Whether a run for `sessionID` is in flight (a test seam).
    func isEscalating(_ sessionID: Int64) -> Bool { inFlight[sessionID] != nil }

    func start() {
        guard !running else { return }
        running = true
        evaluate()
    }

    /// Reads the owner's presence from `center` and evaluates on each of its
    /// changes (it has one `onChange` subscriber: this).
    func follow(presence center: OwnerPresenceCenter) {
        presence = { [weak center] in center?.escalationPresence(sessionID: $0) }
        center.onChange = { [weak self] in self?.evaluate() }
    }

    /// Cancels every run in flight and the tick, and forgets the bookkeeping.
    func stop() {
        running = false
        inFlight.values.forEach { $0.task.cancel() }
        inFlight = [:]
        entries = [:]
        unreadableLogged = [:]
        cancelTick?()
        cancelTick = nil
    }

    /// Decides every session holding a question now and starts the runs due.
    func evaluate() {
        guard running else { return }
        let now = clock()
        let current = sessions()
        forgetAnsweredQuestions(current.rows)
        let questions = current.rows.filter { $0.chatQuestion != nil && $0.chatQuestionAt != nil }
        for row in questions {
            guard inFlight[row.id] == nil, let presence = presence(row.id) else { continue }
            let decision = ChatQuestionEscalationPolicy.decide(
                row: row, live: current.liveIDs.contains(row.id), startedAt: current.startedAt[row.id],
                presence: presence, hasOwnerDraft: hasOwnerDraft(row.id), now: now
            )
            switch decision {
            case .none: continue
            case .unreadableStamp: logUnreadable(row)
            case let .escalate(reason): escalateIfDue(row, reason: reason, now: now)
            }
        }
        // Only a live session's question can escalate (the policy); a
        // stopped one changes with a read, never with time.
        armTick(questions.contains { current.liveIDs.contains($0.id) })
    }

    // MARK: - Runs

    private func escalateIfDue(_ row: SessionAgentStateRow, reason: ChatQuestionEscalationPolicy.Reason, now: Date) {
        guard let projectID = row.projectID, let at = row.chatQuestionAt else { return }
        if let entry = entries[row.id], entry.at == at {
            guard !entry.stopped, now.timeIntervalSince(entry.lastRun) >= Self.retryAfter else { return }
            entries[row.id]?.lastRun = now
        } else {
            entries[row.id] = Entry(at: at, lastRun: now)
        }
        start(session: row.id, projectID: projectID, at: at, reason: reason)
    }

    private func start(session: Int64, projectID: Int64, at: String, reason: ChatQuestionEscalationPolicy.Reason) {
        runsStarted += 1
        let token = runsStarted
        let cli = cli
        let task = Task { [weak self] in
            let result = await cli.escalateQuestion(projectID: projectID, sessionID: session, at: at, reason: reason)
            // A run `stop()` cancelled applies nothing.
            guard !Task.isCancelled else { return }
            self?.finished(session: session, token: token, projectID: projectID, at: at, result: result)
        }
        inFlight[session] = (token, task)
    }

    private func finished(
        session: Int64, token: Int, projectID: Int64, at: String, result: ChatQuestionEscalationResult
    ) {
        guard inFlight[session]?.token == token else { return }
        inFlight[session] = nil
        // Go clears the question in the filing transaction, so a read may
        // have dropped the entry already: a filed ask is announced whatever
        // the bookkeeping says.
        if case let .filed(askID) = result.verdict {
            log("[ChatEscalation] session \(session): question raised as ask #\(askID.map(String.init) ?? "?")")
            onFiled?(projectID)
        }
        guard var entry = entries[session], entry.at == at else { return }
        switch result.verdict {
        case .filed, .gone:
            entry.stopped = true
        case let .transient(message):
            logFailure(&entry, session: session, "escalation failed, retrying in a minute: \(message)")
        case let .failed(message):
            entry.stopped = true
            logFailure(&entry, session: session, "escalation failed, not retried for this question: \(message)")
        }
        entries[session] = entry
    }

    // MARK: - Bookkeeping

    /// Drops what belongs to a question that is no longer the session's.
    private func forgetAnsweredQuestions(_ rows: [SessionAgentStateRow]) {
        let current = Dictionary(rows.map { ($0.id, $0.chatQuestionAt) }) { _, last in last }
        entries = entries.filter { id, entry in current[id] == entry.at }
        unreadableLogged = unreadableLogged.filter { id, at in current[id] == at }
    }

    private func logFailure(_ entry: inout Entry, session: Int64, _ message: String) {
        guard !entry.logged else { return }
        entry.logged = true
        log("[ChatEscalation] session \(session): \(message)")
    }

    private func logUnreadable(_ row: SessionAgentStateRow) {
        guard let at = row.chatQuestionAt, unreadableLogged[row.id] != at else { return }
        unreadableLogged[row.id] = at
        log("[ChatEscalation] session \(row.id): unreadable chat_question_at \(at.debugDescription); not raised")
    }

    private func armTick(_ needed: Bool) {
        guard needed else {
            cancelTick?()
            cancelTick = nil
            return
        }
        guard cancelTick == nil else { return }
        cancelTick = schedule(Self.tickInterval) { [weak self] in
            self?.cancelTick = nil
            self?.evaluate()
        }
    }
}

extension OwnerPresenceCenter {
    /// The escalation policy's presence for `sessionID`; nil until presence
    /// has settled.
    func escalationPresence(sessionID: Int64) -> ChatQuestionEscalationPolicy.Presence? {
        guard hasSettled else { return nil }
        return awaySince(sessionID: sessionID).map { .away(since: $0) } ?? .present
    }
}
