import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Types a Discuss thread's question into the author's session
/// (`SpecReviewThreadCenter`); `SessionLineDelivery` in the app, a fake in
/// tests. The same contract as `SpecReviewLineDelivering`: a held or queued
/// line is not kept, the center tries it again on its next poll; `.noSession`
/// only when the session is surely gone.
@MainActor
protocol SpecReviewQuestionDelivering: AnyObject {
    func deliverSpecReviewQuestion(_ line: String, questionID: Int64, sessionID: Int64) async -> SessionLineDelivery.Delivery
    /// The question closed before its line went: a line filed after it in
    /// the session's order may go now.
    func forgetSpecReviewQuestion(questionID: Int64)
}

extension SessionLineDelivery: SpecReviewQuestionDelivering {
    /// In the session's spec review order (`SpecReviewLineOrder`), behind a
    /// round's findings line filed before it.
    func deliverSpecReviewQuestion(_ line: String, questionID: Int64, sessionID: Int64) async -> Delivery {
        await specReviewLines.send(line, key: .specReviewQuestion(questionID), sessionID: sessionID)
    }

    func forgetSpecReviewQuestion(questionID: Int64) {
        specReviewLines.forget(.specReviewQuestion(questionID))
    }
}

/// Files a thread's question and closes one it could not deliver
/// (`WorkbenchCLI` in the app: Go is the only writer of the questions).
@MainActor
protocol SpecReviewQuestionFiling {
    func specReviewQuestion(askID: Int64, itemKey: String, question: String) async throws -> Int64
    func specReviewCloseQuestion(id: Int64, reason: String) async throws
}

extension WorkbenchCLI: SpecReviewQuestionFiling {}

/// The Discuss threads' app-lifetime half (spec 2026-11-08 §3), owned by
/// `AppState` so it outlives the drawer:
/// - which threads are drawn open, so a thread left open is open again when
///   the ask is reopened;
/// - a thread agent's question to the author: filed through the CLI (Go
///   refuses a second open one in the thread; its words go to the thread),
///   then typed into the ask's session once, through the same per-session
///   spec review order as the loop's findings line (never mid-turn, never
///   over the owner's typing); a held or queued line is tried again on the
///   next poll; no session closes it (`--reason gone`);
/// - the 3 s poll of the questions, only while a thread has an open one;
/// - once a question is answered, expired or gone, the thread's agent gets
///   one follow-up turn with a notice row ("The author answered (question
///   #N): …", "The author did not answer", or — when this app run never saw
///   the question typed — "The question may not have reached the author");
///   a follow-up already present as that row is never sent again, so a
///   thread opened later picks up an answer that landed while the Desktop
///   was closed;
/// - the Fix comment fields drafted from a thread, by thread key, so closing
///   or switching the drawer keeps them for the app run.
///
/// Go writes the questions from another process, so GRDB observation never
/// fires: the poll re-reads them.
@MainActor
@Observable
final class SpecReviewThreadCenter {
    nonisolated static let pollInterval: Duration = .seconds(3)
    nonisolated static let notAnsweredNotice = "The author did not answer"
    /// An expired or gone question this app run never saw typed (filed
    /// before a restart, or its session ended first): it may never have
    /// reached the author.
    nonisolated static let notReachedNotice = "The question may not have reached the author"
    nonisolated static let typedNotice =
        "The question to the author is typed into their session — press Return there to send it."
    nonisolated static let copiedNotice =
        "The question to the author is copied — paste it into their session and press Return."

    nonisolated static func readFailedNotice(_ error: String) -> String {
        "Couldn't read the questions to the author: \(error). Watchtower keeps trying."
    }

    nonisolated static func answeredNotice(questionID: Int64, answer: String) -> String {
        "The author answered (question #\(questionID)): \(answer)"
    }

    nonisolated static func answeredPrompt(questionID: Int64, answer: String) -> String {
        """
        The author answered your question #\(questionID): \(answer)
        Finish your explanation with this answer.
        """
    }

    nonisolated static func notAnsweredPrompt(questionID: Int64) -> String {
        "The author did not answer your question #\(questionID). Continue without the answer."
    }

    /// Threads (conversation keys) drawn open.
    private(set) var openThreads: Set<String> = []
    /// Each polled thread's questions as last read, oldest first.
    private(set) var questions: [String: [SpecReviewQuestionRow]] = [:]
    /// The Fix comment fields drafted from a thread, by thread key
    /// (`SpecReviewModel.fixDrafts` reads its ask's).
    var fixDrafts: [String: SpecReviewFixDraft] = [:]

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let cli: any SpecReviewQuestionFiling
    @ObservationIgnored private let delivery: any SpecReviewQuestionDelivering
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollGeneration = 0
    /// Each thread's chat in the app's center, made again when the idle
    /// sweep let it go.
    @ObservationIgnored private var engines: [String: @MainActor () -> EmbeddedChatEngine?] = [:]
    /// Questions filed this run and not typed yet, by id.
    @ObservationIgnored private var undelivered: [Int64: PendingQuestion] = [:]
    /// Threads whose questions the poll reads.
    @ObservationIgnored private var watched: Set<String> = []
    /// Questions whose follow-up this run handled.
    @ObservationIgnored private var followedUp: Set<Int64> = []
    /// Questions this run saw typed (or copied) into the author's session.
    @ObservationIgnored private var delivered: Set<Int64> = []
    /// Lines for a thread whose chat is not loaded: shown when it registers.
    @ObservationIgnored private var pendingNotices: [String: [String]] = [:]
    /// Threads with a question being filed.
    @ObservationIgnored private var filing: Set<String> = []
    /// A read error is logged once per streak of failures.
    @ObservationIgnored private var failing = false

    private struct PendingQuestion {
        let id: Int64
        let thread: String
        let sessionID: Int64
        let line: String
    }

    init(
        dbPool: DatabasePool,
        cli: any SpecReviewQuestionFiling,
        delivery: any SpecReviewQuestionDelivering,
        pollInterval: Duration = SpecReviewThreadCenter.pollInterval,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.delivery = delivery
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    // MARK: - Open threads

    func isOpen(_ thread: String) -> Bool { openThreads.contains(thread) }

    func setOpen(_ thread: String, _ open: Bool) {
        if open { openThreads.insert(thread) } else { openThreads.remove(thread) }
    }

    // MARK: - Threads and questions

    /// A thread's chat exists (a screen opened it): its questions are read,
    /// and a follow-up for one closed while the Desktop was away or the
    /// chat was let go is sent now.
    func register(thread: String, engine: @escaping @MainActor () -> EmbeddedChatEngine?) async {
        engines[thread] = engine
        watched.insert(thread)
        if let notices = pendingNotices.removeValue(forKey: thread) {
            for notice in notices { tell(thread, notice) }
        }
        await poll()
        startPolling()
    }

    /// A thread's reply ended with a question for the author: it is filed
    /// (Go's refusal, such as "a question is already open in this thread",
    /// goes to the thread instead) and typed into `sessionID`.
    func askAuthor(askID: Int64, sessionID: Int64?, itemKey: String, thread: String, question: String) async {
        guard !filing.contains(thread) else { return }
        filing.insert(thread)
        defer { filing.remove(thread) }
        let id: Int64
        do {
            id = try await cli.specReviewQuestion(askID: askID, itemKey: itemKey, question: question)
        } catch {
            NSLog("SpecReviewThread: ask %lld: filing a question failed: %@", askID, "\(error)")
            tell(thread, error.localizedDescription)
            return
        }
        watched.insert(thread)
        if let sessionID {
            let line = OwnerAskPrompt.specReviewQuestionLine(askID: askID, questionID: id, question: question)
            undelivered[id] = PendingQuestion(id: id, thread: thread, sessionID: sessionID, line: line)
        } else {
            // Go files only for an ask with a session; one the app does not
            // see cannot be typed anywhere.
            await close(id)
        }
        await poll()
        startPolling()
    }

    /// One pass: types the questions not typed yet, then sends the
    /// follow-up of each question that closed. Not private: tests drive it.
    func poll() async {
        var rows = await read()
        guard let before = rows else { return }
        var closed = false
        for pending in undelivered.values.sorted(by: { $0.id < $1.id }) {
            guard !Task.isCancelled else { return }
            guard before.first(where: { $0.id == pending.id })?.state == .open else {
                undelivered[pending.id] = nil
                delivery.forgetSpecReviewQuestion(questionID: pending.id)
                continue
            }
            switch await delivery.deliverSpecReviewQuestion(pending.line, questionID: pending.id,
                                                            sessionID: pending.sessionID) {
            case .submitted:
                undelivered[pending.id] = nil
                delivered.insert(pending.id)
            case .typed:
                // In the session, not sent: the owner presses Return.
                undelivered[pending.id] = nil
                delivered.insert(pending.id)
                tell(pending.thread, Self.typedNotice)
            case .copied:
                undelivered[pending.id] = nil
                delivered.insert(pending.id)
                tell(pending.thread, Self.copiedNotice)
            case .held, .queued:
                break
            case .noSession:
                undelivered[pending.id] = nil
                await close(pending.id)
                closed = true
            }
        }
        if closed { rows = await read() }
        guard let all = rows else { return }
        let byThread = Dictionary(grouping: all, by: \.thread)
        for (thread, threadRows) in byThread where questions[thread] != threadRows {
            questions[thread] = threadRows
        }
        for (_, threadRows) in byThread {
            for row in threadRows where row.state != .open { followUp(row, in: threadRows) }
        }
        watched = Set(all.filter { $0.state == .open }.map(\.thread)).union(undelivered.values.map(\.thread))
    }

    func start() {
        startPolling()
    }

    func stop() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    /// The watched threads' questions; nil when the read failed: logged
    /// and said in each watched thread once per streak of failures.
    private func read() async -> [SpecReviewQuestionRow]? {
        let threads = Array(watched.union(undelivered.values.map(\.thread)))
        guard !threads.isEmpty else { return [] }
        do {
            let rows = try await dbPool.read { db in try SpecReviewThreadQueries.questions(db, threads: threads) }
            failing = false
            return rows
        } catch {
            if !failing {
                NSLog("SpecReviewThread: read failed: %@", "\(error)")
                for thread in threads.sorted() { tell(thread, Self.readFailedNotice(error.localizedDescription)) }
            }
            failing = true
            return nil
        }
    }

    /// A line from Watchtower in the thread: in its chat when one is
    /// loaded, else when the thread next registers.
    private func tell(_ thread: String, _ notice: String) {
        if let engine = engines[thread]?() {
            engine.appendLocal(role: "system", text: notice)
        } else {
            pendingNotices[thread, default: []].append(notice)
        }
    }

    /// Closes a question that cannot be typed. A failure (it was answered
    /// or expired meanwhile: "the question is closed") is logged; the next
    /// read shows what it is.
    private func close(_ id: Int64) async {
        do {
            try await cli.specReviewCloseQuestion(id: id, reason: "gone")
        } catch {
            NSLog("SpecReviewThread: question %lld: close failed: %@", id, "\(error)")
        }
    }

    /// The thread's agent turns to a closed question: its notice row, then a
    /// follow-up turn. Skipped when that row is already in the thread (an
    /// earlier run sent it) or no chat of the thread is known this run (the
    /// next `register` sends it).
    private func followUp(_ row: SpecReviewQuestionRow, in threadRows: [SpecReviewQuestionRow]) {
        guard !followedUp.contains(row.id), let engine = engines[row.thread]?() else { return }
        let notices = engine.messages.map(\.message).filter { $0.role == "system" }.map(\.text)
        let notice: String
        let prompt: String
        let alreadySent: Bool
        switch row.state {
        case .answered:
            notice = Self.answeredNotice(questionID: row.id, answer: row.answer)
            prompt = Self.answeredPrompt(questionID: row.id, answer: row.answer)
            alreadySent = notices.contains(notice)
        case .expired, .gone:
            notice = delivered.contains(row.id) ? Self.notAnsweredNotice : Self.notReachedNotice
            prompt = Self.notAnsweredPrompt(questionID: row.id)
            // The notice names no question: the n-th unanswered one is sent
            // when the thread holds fewer than n such rows (of either wording).
            let unanswered = threadRows.filter { $0.state == .expired || $0.state == .gone }
            let index = unanswered.firstIndex { $0.id == row.id } ?? 0
            let sent = notices.filter { $0 == Self.notAnsweredNotice || $0 == Self.notReachedNotice }.count
            alreadySent = index < sent
        case .open, .unknown:
            return
        }
        followedUp.insert(row.id)
        guard !alreadySent else { return }
        engine.sendFollowUp(prompt: prompt, notice: notice)
    }

    private func startPolling() {
        guard pollTask == nil, !watched.isEmpty || !undelivered.isEmpty else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self, pollInterval, sleep] in
            while !Task.isCancelled {
                try? await sleep(pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.poll()
                if self.watched.isEmpty, self.undelivered.isEmpty { break }
            }
            if let self, self.pollGeneration == generation { self.pollTask = nil }
        }
    }
}
