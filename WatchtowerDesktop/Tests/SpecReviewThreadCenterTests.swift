import XCTest
import GRDB
import WatchtowerTestSupport
import WatchtowerCore
@testable import WatchtowerDesktop

/// What the question's line met in the session, one answer per try.
@MainActor
private final class FakeQuestionDelivery: SpecReviewQuestionDelivering {
    var answers: [SessionLineDelivery.Delivery] = []
    private(set) var lines: [(line: String, questionID: Int64, sessionID: Int64)] = []

    func deliverSpecReviewQuestion(_ line: String, questionID: Int64, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        lines.append((line, questionID, sessionID))
        return answers.isEmpty ? .submitted : answers.removeFirst()
    }

    private(set) var forgotten: [Int64] = []
    func forgetSpecReviewQuestion(questionID: Int64) { forgotten.append(questionID) }
}

/// Go's `spec-review question`: files a row (or refuses), closes one.
@MainActor
private final class FakeQuestionCLI: SpecReviewQuestionFiling {
    let pool: DatabasePool
    var refusal: String?
    private(set) var filed: [(askID: Int64, itemKey: String, question: String)] = []
    private(set) var closed: [(id: Int64, reason: String)] = []
    /// The thread key Go computes for a question.
    var thread: (Int64, String) -> String = { _, _ in "" }

    init(pool: DatabasePool) { self.pool = pool }

    func specReviewQuestion(askID: Int64, itemKey: String, question: String) async throws -> Int64 {
        filed.append((askID, itemKey, question))
        if let refusal { throw WorkbenchCLIError.refused(refusal) }
        let thread = thread(askID, itemKey)
        return try await pool.write { d in
            try d.execute(sql: """
                INSERT INTO spec_review_questions (ask_id, thread, item_key, question, created_at)
                VALUES (?, ?, ?, ?, '2026-11-08T10:00:00Z')
                """, arguments: [askID, thread, itemKey, question])
            return d.lastInsertedRowID
        }
    }

    func specReviewCloseQuestion(id: Int64, reason: String) async throws {
        closed.append((id, reason))
        try await pool.write { d in
            try d.execute(sql: "UPDATE spec_review_questions SET state = ? WHERE id = ? AND state = 'open'",
                          arguments: [reason, id])
        }
    }
}

/// Both spec review lines through one `SpecReviewLineOrder`, over a
/// session where the owner is typing for the first tries.
@MainActor
private final class OrderedDelivery: SpecReviewLineDelivering, SpecReviewQuestionDelivering {
    var answers: [SessionLineDelivery.Delivery] = []
    private(set) var tried: [String] = []
    private(set) var pasted: [String] = []
    lazy var order = SpecReviewLineOrder { [weak self] line, _, _ in
        guard let self else { return .noSession }
        self.tried.append(line)
        let answer = self.answers.isEmpty ? .submitted : self.answers.removeFirst()
        if answer == .submitted { self.pasted.append(line) }
        return answer
    }

    func deliverSpecReviewLine(_ line: String, askID: Int64, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        await order.send(line, key: .specReview(askID), sessionID: sessionID)
    }

    func deliverSpecReviewQuestion(_ line: String, questionID: Int64, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        await order.send(line, key: .specReviewQuestion(questionID), sessionID: sessionID)
    }

    func forgetSpecReviewLine(askID: Int64) { order.forget(.specReview(askID)) }
    func forgetSpecReviewQuestion(questionID: Int64) { order.forget(.specReviewQuestion(questionID)) }
}

/// The reveal half of a loop, recorded.
@MainActor
private final class RecordingReveal: SpecReviewRevealing {
    private(set) var asks: [Int64] = []
    func specReviewReveal(askID: Int64, reason: String) async throws { asks.append(askID) }
}

@MainActor
private final class NoReveal: SpecReviewRevealing {
    func specReviewReveal(askID: Int64, reason: String) async throws {}
}

/// `SpecReviewThreadCenter` (spec 2026-11-08 §3): a thread's question to
/// the author is filed, typed once through the session's spec review order,
/// closed when there is no session, and its answer (or none) starts the
/// thread agent's next turn exactly once.
@MainActor
final class SpecReviewThreadCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var delivery: FakeQuestionDelivery!
    private var cli: FakeQuestionCLI!
    private var center: SpecReviewThreadCenter!
    private var ai: ScriptedAIService!
    /// The AI services' call counts on Observation, for `waitUntil`.
    private var aiCounters: [CallCountingAI] = []
    private var chats: EmbeddedChatCenter!
    private var project: Int64 = 0
    private var session: Int64 = 0
    private var askID: Int64 = 0
    private let item = "ag:2"

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        delivery = FakeQuestionDelivery()
        cli = FakeQuestionCLI(pool: pool)
        (project, session, askID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "s", folderPath: "/tmp/acme"))
            let a = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, kind: "review", docPath: "docs/spec.md")
            return (p, s.id, a)
        }
        cli.thread = { [project] ask, key in
            SpecReviewThreadKey.contextID(workbenchID: project, rootAskID: ask, itemKey: key)
        }
        center = makeCenter()
        ai = ScriptedAIService()
        chats = makeChats(ai)
    }

    override func tearDown() async throws {
        center.stop()
        for index in ai.calls.indices { ai.finish(call: index) }
        TestDatabase.cleanup(path: path)
    }

    private func makeCenter(delivery: (any SpecReviewQuestionDelivering)? = nil) -> SpecReviewThreadCenter {
        // The poll's clock never fires: the tests drive `poll()` themselves.
        SpecReviewThreadCenter(dbPool: pool, cli: cli, delivery: delivery ?? self.delivery) { _ in
            try await parkUntilTaskCancelled()
        }
    }

    private func makeChats(_ ai: ScriptedAIService) -> EmbeddedChatCenter {
        let pool: DatabasePool = pool
        let counter = CallCountingAI(ai)
        aiCounters.append(counter)
        return EmbeddedChatCenter { spec, gate in
            guard case .database(let conversationID) = spec.persistence else { preconditionFailure("database chat") }
            return EmbeddedChatEngine(spec: spec, store: DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID),
                                      aiService: counter, gate: gate)
        }
    }

    private var thread: String {
        SpecReviewThreadKey.contextID(workbenchID: project, rootAskID: askID, itemKey: item)
    }

    /// The thread's chat in `chats`, as a findings screen makes it.
    private func engineMaker(_ chats: EmbeddedChatCenter) async throws -> @MainActor () -> EmbeddedChatEngine? {
        let conversation = try await SpecReviewThreadSurface.conversationID(
            workbenchID: project, rootAskID: askID, itemKey: item, title: "Mute is per channel", dbPool: pool)
        let context = SpecReviewThreadContext(workbenchID: project, rootAskID: askID, askID: askID, itemKey: item,
                                              data: "data", provider: .claude)
        let spec = SpecReviewThreadSurface.spec(context: context, conversationID: conversation, dbPool: pool)
        return { chats.engine(for: spec) }
    }

    private func setState(_ id: Int64, _ state: String, answer: String = "") async throws {
        try await pool.write { d in
            try d.execute(sql: "UPDATE spec_review_questions SET state = ?, answer = ? WHERE id = ?",
                          arguments: [state, answer, id])
        }
    }

    /// Waits until `condition` holds, re-checking on every change of the
    /// observable state it reads and on every AI call — no deadline.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let counters = aiCounters
        await untilObserved {
            counters.forEach { _ = $0.count }
            return condition()
        }
    }

    private func systemRows(_ engine: EmbeddedChatEngine) -> [String] {
        engine.messages.map(\.message).filter { $0.role == "system" }.map(\.text)
    }

    private func askAuthor(_ question: String = "Per user?") async {
        await center.askAuthor(askID: askID, sessionID: session, itemKey: item, thread: thread, question: question)
    }

    // MARK: - Delivery

    func testDeliversOnceThroughLineDelivery() async throws {
        await askAuthor()
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        XCTAssertEqual(cli.filed.map(\.question), ["Per user?"])
        XCTAssertEqual(delivery.lines.map(\.line), [OwnerAskPrompt.specReviewQuestionLine(askID: askID, questionID: id,
                                                                                          question: "Per user?")])
        XCTAssertEqual(delivery.lines.first?.sessionID, session)
        await center.poll()
        await center.poll()
        XCTAssertEqual(delivery.lines.count, 1, "typed once")
        XCTAssertEqual(center.questions[thread]?.first?.state, .open)
    }

    /// The owner is typing in the session: the line is held, tried again on
    /// the next poll, and goes once.
    func testHeldWhileOwnerTyping() async throws {
        delivery.answers = [.held, .queued, .held, .submitted]
        await askAuthor()
        XCTAssertEqual(delivery.lines.count, 1)
        await center.poll()
        await center.poll()
        await center.poll()
        XCTAssertEqual(delivery.lines.count, 4)
        await center.poll()
        await center.poll()
        XCTAssertEqual(delivery.lines.count, 4, "never typed again once it went")
        XCTAssertEqual(Set(delivery.lines.map(\.line)).count, 1)
    }

    func testNoSessionClosesGone() async throws {
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        delivery.answers = [.noSession]
        await askAuthor()
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        XCTAssertEqual(cli.closed.map(\.id), [id])
        XCTAssertEqual(cli.closed.map(\.reason), ["gone"])
        XCTAssertEqual(center.questions[thread]?.first?.state, .gone, "the thread's row says the session has ended")
        let engine = try XCTUnwrap(make())
        await waitUntil { self.ai.calls.count == 1 }
        XCTAssertTrue(ai.calls[0].prompt.contains(SpecReviewThreadCenter.notAnsweredPrompt(questionID: id)))
        await waitUntil { self.systemRows(engine).contains(SpecReviewThreadCenter.notReachedNotice) }
        XCTAssertFalse(systemRows(engine).contains(SpecReviewThreadCenter.notAnsweredNotice),
                       "never typed this run: it may not have reached the author")
        await center.poll()
        XCTAssertEqual(delivery.lines.count, 1, "a closed question is never typed")
    }

    /// A question filed before a restart and never typed this run expires:
    /// the thread says it may not have reached the author, once.
    func testExpiredWithoutDeliveryThisRunMayNotHaveReachedTheAuthor() async throws {
        let id = try await pool.write { [askID, item, thread] d in
            try d.execute(sql: """
                INSERT INTO spec_review_questions (ask_id, thread, item_key, question, state, created_at)
                VALUES (?, ?, ?, 'Per user?', 'expired', '2026-11-08T10:00:00Z')
                """, arguments: [askID, thread, item])
            return d.lastInsertedRowID
        }
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        let engine = try XCTUnwrap(make())
        await waitUntil { self.ai.calls.count == 1 }
        XCTAssertTrue(ai.calls[0].prompt.contains(SpecReviewThreadCenter.notAnsweredPrompt(questionID: id)))
        await waitUntil { self.systemRows(engine).contains(SpecReviewThreadCenter.notReachedNotice) }
        ai.emit(.text("Done."), .turnComplete("Done."), .done)
        ai.finish()
        await engine.finished()
        await center.poll()
        XCTAssertEqual(ai.calls.count, 1, "the follow-up goes once")
    }

    /// Typed without Return, or only copied: the thread tells the owner
    /// what to do in the author's session.
    func testTypedAndCopiedTellTheOwner() async throws {
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        delivery.answers = [.typed]
        await askAuthor()
        let engine = try XCTUnwrap(make())
        await waitUntil { self.systemRows(engine).contains(SpecReviewThreadCenter.typedNotice) }

        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        try await setState(id, "answered", answer: "Per channel")
        await center.poll()
        await waitUntil { self.ai.calls.count == 1 }
        ai.emit(.text("Done."), .turnComplete("Done."), .done)
        ai.finish()
        await engine.finished()
        delivery.answers = [.copied]
        await askAuthor("Calendar day?")
        await waitUntil { self.systemRows(engine).contains(SpecReviewThreadCenter.copiedNotice) }
    }

    /// A refusal for a thread whose chat is not loaded is not lost: it
    /// shows when the thread registers.
    func testRefusalWithoutAChatShowsWhenTheThreadOpens() async throws {
        cli.refusal = "a question is already open in this thread"
        await askAuthor()
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        let engine = try XCTUnwrap(make())
        await waitUntil { self.systemRows(engine).contains("a question is already open in this thread") }
    }

    /// A failed read of the questions is said in the thread, once per
    /// streak of failures.
    func testReadFailureIsSaidInTheThread() async throws {
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        await askAuthor()
        try await pool.write { d in try d.execute(sql: "DROP TABLE spec_review_questions") }
        await center.poll()
        await center.poll()
        let engine = try XCTUnwrap(make())
        await waitUntil { self.systemRows(engine).contains { $0.hasPrefix("Couldn't read the questions to the author:") } }
        XCTAssertEqual(systemRows(engine).filter { $0.hasPrefix("Couldn't read the questions") }.count, 1)
    }

    /// Go refuses a second open question in the thread: its words go to the
    /// thread and nothing is typed.
    func testRefusalGoesToTheThread() async throws {
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        cli.refusal = "a question is already open in this thread"
        await askAuthor()
        XCTAssertTrue(delivery.lines.isEmpty)
        let engine = try XCTUnwrap(make())
        await waitUntil { self.systemRows(engine).contains("a question is already open in this thread") }
    }

    /// A hidden loop's findings line and a thread's question for the same
    /// session go one at a time, in filing order: the question waits while
    /// the findings line is held, and is never tried before it.
    func testQuestionAndFindingsLineQueueInOrder() async throws {
        let ordered = OrderedDelivery()
        ordered.answers = [.held, .held]
        center = makeCenter(delivery: ordered)
        let loopAsk = try await pool.write { [project, session] d in
            let id = try TestDatabase.insertOwnerAsk(d, projectID: project, sessionID: session, kind: "review",
                                                     docPath: "docs/plan.md")
            try d.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, queued_at, finished_at, loop, round, open_items)
                VALUES (?, 'done', '2026-11-08T09:59:00Z', '2026-11-08T10:00:00Z', 'author', 2,
                        '[{"key":"ag:1","kind":"agreement","text":"a","note":"","round":1}]')
                """, arguments: [id])
            return id
        }
        let loop = SpecReviewLoopCenter(dbPool: pool, delivery: ordered, cli: NoReveal())
        let findings = OwnerAskPrompt.specReviewLine(askID: loopAsk, round: 2, items: 1)

        await loop.poll()                     // filed first: held (owner typing)
        await askAuthor()                     // filed second: waits, not tried
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        let question = OwnerAskPrompt.specReviewQuestionLine(askID: askID, questionID: id, question: "Per user?")
        XCTAssertEqual(ordered.tried, [findings])
        await center.poll()                   // still behind the findings line
        XCTAssertEqual(ordered.tried, [findings])
        await loop.poll()                     // held again
        await center.poll()
        await loop.poll()                     // goes
        await center.poll()                   // then the question
        await loop.poll()
        await center.poll()
        XCTAssertEqual(ordered.tried, [findings, findings, findings, question])
        XCTAssertEqual(ordered.pasted, [findings, question])
    }

    /// A held loop round, inserted for the order tests.
    private func insertLoopRound() async throws -> Int64 {
        try await pool.write { [project, session] d in
            let id = try TestDatabase.insertOwnerAsk(d, projectID: project, sessionID: session, kind: "review",
                                                     docPath: "docs/plan.md")
            try d.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, queued_at, finished_at, loop, round, open_items)
                VALUES (?, 'done', '2026-11-08T09:59:00Z', '2026-11-08T10:00:00Z', 'author', 2,
                        '[{"key":"ag:1","kind":"agreement","text":"a","note":"","round":1}]')
                """, arguments: [id])
            return id
        }
    }

    /// A question held at the head of the order closes (expired): it is
    /// forgotten at once, and the findings line filed after it goes on the
    /// loop's next poll, with no 30 s wait.
    func testClosedQuestionLetsTheNextLineGo() async throws {
        let ordered = OrderedDelivery()
        ordered.answers = [.held]
        center = makeCenter(delivery: ordered)
        await askAuthor()
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        let loopAsk = try await insertLoopRound()
        let loop = SpecReviewLoopCenter(dbPool: pool, delivery: ordered, cli: NoReveal())
        let findings = OwnerAskPrompt.specReviewLine(askID: loopAsk, round: 2, items: 1)
        await loop.poll()
        XCTAssertFalse(ordered.tried.contains(findings), "behind the held question")
        try await setState(id, "expired")
        await center.poll()
        await loop.poll()
        XCTAssertEqual(ordered.pasted, [findings])
    }

    /// Show Now on a loop whose line is held at the head: the question
    /// filed after it goes on the thread's next poll.
    func testShowNowLetsTheQuestionGo() async throws {
        let ordered = OrderedDelivery()
        ordered.answers = [.held]
        center = makeCenter(delivery: ordered)
        let loopAsk = try await insertLoopRound()
        let loop = SpecReviewLoopCenter(dbPool: pool, delivery: ordered, cli: RecordingReveal())
        await loop.poll()
        await askAuthor()
        XCTAssertTrue(ordered.pasted.isEmpty)
        _ = await loop.showNow(askID: loopAsk)
        await center.poll()
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        XCTAssertEqual(ordered.pasted, [OwnerAskPrompt.specReviewQuestionLine(askID: askID, questionID: id,
                                                                              question: "Per user?")])
    }

    // MARK: - Follow-ups

    func testAnswerStartsFollowUpOnce() async throws {
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        await askAuthor()
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        try await setState(id, "answered", answer: "Per channel, as agreed")
        await center.poll()
        let engine = try XCTUnwrap(make())
        await waitUntil { self.ai.calls.count == 1 }
        XCTAssertTrue(ai.calls[0].prompt.contains(
            SpecReviewThreadCenter.answeredPrompt(questionID: id, answer: "Per channel, as agreed")))
        let notice = SpecReviewThreadCenter.answeredNotice(questionID: id, answer: "Per channel, as agreed")
        XCTAssertEqual(notice, "The author answered (question #\(id)): Per channel, as agreed")
        await waitUntil { self.systemRows(engine).contains(notice) }
        ai.emit(.text("It holds."), .turnComplete("It holds."), .done)
        ai.finish()
        await engine.finished()
        await center.poll()
        await center.poll()
        await engine.finished()
        XCTAssertEqual(ai.calls.count, 1, "one follow-up turn")
        XCTAssertEqual(systemRows(engine).filter { $0 == notice }.count, 1)
    }

    func testExpiredSaysAuthorDidNotAnswer() async throws {
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        await askAuthor()
        let id = try XCTUnwrap(center.questions[thread]?.first?.id)
        try await setState(id, "expired")
        await center.poll()
        let engine = try XCTUnwrap(make())
        await waitUntil { self.ai.calls.count == 1 }
        XCTAssertTrue(ai.calls[0].prompt.contains("Continue without the answer"))
        await waitUntil { self.systemRows(engine).contains("The author did not answer") }
        XCTAssertEqual(center.questions[thread]?.first?.state, .expired)
    }

    /// The author answered while the Desktop was closed: the thread, opened
    /// in the next run, gets the follow-up; a run after that, which finds
    /// the notice row in the thread, sends nothing.
    func testAnswerLandedWhileClosedPickedUpOnOpen() async throws {
        let id = try await pool.write { [askID, item, thread] d in
            try d.execute(sql: """
                INSERT INTO spec_review_questions (ask_id, thread, item_key, question, answer, state, created_at)
                VALUES (?, ?, ?, 'Per user?', 'Per channel', 'answered', '2026-11-08T10:00:00Z')
                """, arguments: [askID, thread, item])
            return d.lastInsertedRowID
        }
        let make = try await engineMaker(chats)
        await center.register(thread: thread, engine: make)
        let engine = try XCTUnwrap(make())
        await waitUntil { self.ai.calls.count == 1 }
        XCTAssertTrue(ai.calls[0].prompt.contains("Per channel"))
        let notice = SpecReviewThreadCenter.answeredNotice(questionID: id, answer: "Per channel")
        await waitUntil { self.systemRows(engine).contains(notice) }
        ai.emit(.text("Done."), .turnComplete("Done."), .done)
        ai.finish()
        await engine.finished()

        // The next run: a new center and new chats over the same database.
        let laterAI = ScriptedAIService()
        let laterChats = makeChats(laterAI)
        let later = makeCenter()
        let laterMake = try await engineMaker(laterChats)
        await later.register(thread: thread, engine: laterMake)
        let laterEngine = try XCTUnwrap(laterMake())
        await laterEngine.finished()
        XCTAssertTrue(laterAI.calls.isEmpty, "the follow-up is already in the thread")
        XCTAssertEqual(systemRows(laterEngine).filter { $0 == notice }.count, 1)
        later.stop()
    }

    // MARK: - Open threads

    func testOpenThreadsOutliveTheScreen() {
        XCTAssertFalse(center.isOpen(thread))
        center.setOpen(thread, true)
        XCTAssertTrue(center.isOpen(thread))
        center.setOpen(thread, false)
        XCTAssertFalse(center.isOpen(thread))
    }
}
