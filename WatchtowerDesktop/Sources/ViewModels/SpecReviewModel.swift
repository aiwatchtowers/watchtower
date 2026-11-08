import Foundation
import Observation
import GRDB
import WatchtowerCore

/// A finding as one chapter lists it (named apart from Core's markable
/// `SpecReviewFinding`, which carries only the fields the answer needs).
enum SpecReviewChapterFinding: Equatable {
    case agreement(SpecReviewResult.Agreement)
    case decidedAlone(SpecReviewResult.DecidedAlone)
    case blindSpot(SpecReviewResult.BlindSpot)
    /// A finding the owner added from a Discuss thread (spec 2026-11-08 §3).
    case fromDiscussion(SpecReviewProposedFinding)

    var key: String {
        switch self {
        case let .agreement(f): f.key
        case let .decidedAlone(f): f.key
        case let .blindSpot(f): f.key
        case let .fromDiscussion(f): f.key
        }
    }

    var severity: SpecReviewSeverity? {
        switch self {
        case let .agreement(f): f.severity
        case let .decidedAlone(f): f.severity
        case let .blindSpot(f): f.severity
        case let .fromDiscussion(f): f.severity
        }
    }

    var chapter: String {
        switch self {
        case let .agreement(f): f.chapter
        case let .decidedAlone(f): f.chapter
        case let .blindSpot(f): f.chapter
        case let .fromDiscussion(f): f.chapter
        }
    }
}

/// One chapter of the Chapters phase: its slice of the document, the
/// findings and lens checks the reviewer filed under it, and whether the
/// owner marked it Viewed. Findings whose chapter key is unknown land in a
/// trailing chapter `other` titled Other, never dropped.
struct SpecReviewChapterVM: Equatable, Identifiable {
    static let otherKey = "other"

    let key: String
    let heading: String
    let excerpt: Substring
    let findings: [SpecReviewChapterFinding]
    let checks: [SpecReviewResult.Check]
    let viewed: Bool

    var id: String { key }
}

/// Drives one review ask's spec-review screen: the reviewer's stored result,
/// the owner's marks, the 3 s poll while the reviewer runs, Run/Re-run
/// reviewer through the CLI, and Send/Approve through the ask's one answer
/// path (`OwnerAsksViewModel.answer`).
@MainActor
@Observable
final class SpecReviewModel {
    private(set) var row: SpecReviewRow?
    private(set) var marks: [String: SpecReviewMark] = [:]
    /// Findings the owner added to this ask from a Discuss thread (Go writes
    /// `spec_review_thread_findings`); they sit in their chapter, or Other.
    private(set) var threadFindings: [SpecReviewProposedFinding] = []
    /// The first ask of this ask's review chain: the middle part of its
    /// threads' keys (`SpecReviewThreadKey`). The ask itself until loaded.
    private(set) var rootAskID: Int64
    var phase: ReviewPhase = .meaning
    var chapterKey: String?
    var lastError: String?
    /// The footer's Approve asked to confirm (unmarked findings, or an
    /// unanswered dispute after an early end).
    var confirmingApprove = false
    /// The Discuss threads opened on this screen, by item key (spec
    /// 2026-11-08 §3); their chats live in `chats`.
    private(set) var threadStates: [String: SpecReviewThreadState] = [:]
    /// The questions the threads' agent put to the author (Go writes them).
    private(set) var threadQuestions: [SpecReviewQuestionRow] = []
    /// Item key → the finished messages its thread holds on disk.
    private(set) var threadMessageCounts: [String: Int] = [:]

    @ObservationIgnored let ask: OwnerAsk
    @ObservationIgnored let dbPool: DatabasePool
    @ObservationIgnored let cli: WorkbenchCLI
    @ObservationIgnored private let asks: OwnerAsksViewModel
    /// The app's embedded chats; nil: this screen has no Discuss threads.
    @ObservationIgnored let chats: EmbeddedChatCenter?
    /// The provider a thread opens on: the configured one, at its strong tier.
    @ObservationIgnored var configuredProvider: () -> AIProvider = {
        AIProvider.fromConfig(ConfigService().aiProvider)
    }
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    /// Bumped on every start and stop, so a finishing Task clears `pollTask`
    /// only when it is still the current one.
    @ObservationIgnored private var pollGeneration = 0

    init(
        ask: OwnerAsk,
        dbPool: DatabasePool,
        cli: WorkbenchCLI,
        asks: OwnerAsksViewModel,
        chats: EmbeddedChatCenter? = nil,
        pollInterval: Duration = .seconds(3),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.ask = ask
        self.rootAskID = ask.id
        self.dbPool = dbPool
        self.cli = cli
        self.asks = asks
        self.chats = chats
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    deinit { pollTask?.cancel() }

    // MARK: - Loading and polling

    func load() async {
        let askID = ask.id
        do {
            let (row, marks, found, root) = try await dbPool.read { db in
                (try SpecReviewQueries.row(db, askID: askID), try SpecReviewQueries.marks(db, askID: askID),
                 try SpecReviewThreadQueries.threadFindings(db, askID: askID),
                 try SpecReviewThreadQueries.chainRoot(db, askID: askID))
            }
            // A finished author loop opens on its disputes (spec 2026-10-26 §6).
            if self.row == nil, row?.loop == .owner { phase = .wrapup }
            self.row = row
            self.marks = marks
            if found != threadFindings { threadFindings = found }
            rootAskID = root
            if chapterKey == nil || !chapters.contains(where: { $0.key == chapterKey }) {
                chapterKey = chapters.first?.key
            }
        } catch {
            lastError = "Could not read the spec review: \(error.localizedDescription)"
            return
        }
        await loadThreads()
    }

    var isReviewerActive: Bool { row?.status == .queued || row?.status == .running }
    var isPolling: Bool { pollTask != nil }

    /// Reloads every `pollInterval` while the reviewer is queued or running;
    /// ends by itself on done/failed/skipped. One Task, cancelled by
    /// `stopPolling` and deinit.
    func startPolling() {
        guard pollTask == nil, isReviewerActive else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval, let sleep = self?.sleep else { return }
                try? await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                await self.load()
                if !self.isReviewerActive { break }
            }
            if let self, self.pollGeneration == generation { self.pollTask = nil }
        }
    }

    /// After the first `load`: the reviewer is queued just after the ask is
    /// filed, so a missing row is looked for again (`missingRowChecks`
    /// times, one `pollInterval` apart), then the poll starts while the
    /// reviewer is queued or running. Returns once the poll is started (or
    /// not needed); cancelled with the caller's Task.
    func followReviewer() async {
        for _ in 0..<Self.missingRowChecks where row == nil {
            try? await sleep(pollInterval)
            guard !Task.isCancelled else { return }
            await load()
        }
        guard !Task.isCancelled else { return }
        startPolling()
    }

    /// How many times a missing reviewer row is looked for.
    static let missingRowChecks = 10

    func stopPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// Test seam: returns when the poll Task has ended.
    func waitForPolling() async {
        await pollTask?.value
    }

    // MARK: - Run reviewer

    /// Run reviewer / Re-run reviewer. The buttons pass `force: true`: the
    /// CLI refuses a done, failed or skipped row without it. Exit 3 also
    /// means a run is in progress.
    func runReviewer(force: Bool = true) async {
        do {
            try await cli.specReviewStart(askID: ask.id, force: force)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await load()
        startPolling()
    }

    // MARK: - Marks

    /// A comment keeps its finding's text (`about`), so it still says what
    /// it was about once a re-run drops the finding.
    func mark(_ key: String, _ state: SpecReviewMarkState, body: String = "") async {
        let askID = ask.id
        var about = ""
        if state == .comment {
            let finding = row?.result?.findings.first { $0.key == key }?.text
                ?? row?.ledger.first { $0.item.key == key }?.item.text
                ?? threadFindings.first { $0.key == key }.map(\.headline)
            about = finding ?? marks[key]?.about ?? ""
        }
        let mark = SpecReviewMark(key: key, state: state, body: body, about: about)
        let stamp = now()
        do {
            try await dbPool.write { db in
                try SpecReviewQueries.setMark(db, askID: askID, mark: mark, now: stamp)
            }
            marks[key] = mark
        } catch {
            lastError = "Could not save the mark: \(error.localizedDescription)"
        }
    }

    func unmark(_ key: String) async {
        let askID = ask.id
        do {
            try await dbPool.write { db in
                try SpecReviewQueries.clearMark(db, askID: askID, key: key)
            }
            marks[key] = nil
        } catch {
            lastError = "Could not clear the mark: \(error.localizedDescription)"
        }
    }

    // MARK: - Author loop (spec 2026-10-26 §6)

    /// The reviewer↔author loop ended and the owner has the last word: the
    /// screen shows the disputes and the author's fixes instead of marks.
    var isLoop: Bool { row?.loop == .owner }

    /// Findings the two sides argued over, in ledger order.
    var disputes: [SpecReviewLedgerEntry] { bySeverity(row.map(SpecReviewLoop.disputed) ?? []) }

    /// Findings the author never answered (or fixed unchecked), in ledger order.
    var unanswered: [SpecReviewLedgerEntry] { bySeverity(row.map(SpecReviewLoop.unanswered) ?? []) }

    /// Findings the reviewer judged fixed by the author.
    var fixes: [SpecReviewLedgerEntry] { bySeverity(row.map(SpecReviewLoop.fixed) ?? []) }

    private func bySeverity(_ entries: [SpecReviewLedgerEntry]) -> [SpecReviewLedgerEntry] {
        SpecReviewPresentation.sortedBySeverity(entries, \.item.severity)
    }

    var endedEarly: Bool { row.map(SpecReviewLoop.endedEarly) ?? false }

    /// Disputed and unanswered findings the owner has not picked on; Approve
    /// counts them as **Author is right** / **Skip**.
    var unpickedDisputeCount: Int {
        (disputes + unanswered).filter { marks[$0.item.key] == nil }.count
    }

    /// **Reviewer is right** (a `comment` mark, the owner's words optional)
    /// or **Author is right** (`ok`).
    func pick(_ key: String, reviewerRight: Bool, body: String = "") async {
        if reviewerRight {
            await mark(key, .comment, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            await mark(key, .ok)
        }
    }

    /// **Reopen** a fix: a `comment` mark that needs the owner's words.
    /// Returns false, saving nothing, for a blank body.
    @discardableResult
    func reopen(_ key: String, body: String) async -> Bool {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            lastError = "Say what is wrong with the fix to reopen it."
            return false
        }
        await mark(key, .comment, body: body)
        return true
    }

    // MARK: - Derived screen state

    var chapters: [SpecReviewChapterVM] {
        guard let result = row?.result else { return [] }
        let known = Set(result.chapters.map(\.key))
        func inChapter(_ key: String) -> Bool { known.contains(key) }
        let all: [SpecReviewChapterFinding] = result.agreements.map { .agreement($0) }
            + result.decidedAlone.map { .decidedAlone($0) }
            + result.blindSpots.map { .blindSpot($0) }
            + threadFindings.map { .fromDiscussion($0) }
        func findings(_ pick: (String) -> Bool) -> [SpecReviewChapterFinding] {
            SpecReviewPresentation.sortedBySeverity(all.filter { pick($0.chapter) }, \.severity)
        }
        var out = result.chapters.map { chapter in
            SpecReviewChapterVM(
                key: chapter.key,
                heading: chapter.heading,
                excerpt: Self.excerpt(of: ask.docSnapshot, chapter),
                findings: findings { $0 == chapter.key },
                checks: result.checks.filter { $0.chapter == chapter.key },
                viewed: marks[chapter.key]?.state == .viewed
            )
        }
        let rest = findings { !inChapter($0) }
        let restChecks = result.checks.filter { !inChapter($0.chapter) }
        if !rest.isEmpty || !restChecks.isEmpty {
            out.append(SpecReviewChapterVM(
                key: SpecReviewChapterVM.otherKey,
                heading: "Other",
                excerpt: "",
                findings: rest,
                checks: restChecks,
                viewed: marks[SpecReviewChapterVM.otherKey]?.state == .viewed
            ))
        }
        return out
    }

    /// The chapter's slice of the snapshot; `start`/`end` are UTF-8 bytes. A
    /// bad range or one cutting a character reads as empty.
    private static func excerpt(of snapshot: String, _ chapter: SpecReviewResult.Chapter) -> Substring {
        let bytes = snapshot.utf8
        guard chapter.start >= 0, chapter.start <= chapter.end, chapter.end <= bytes.count else { return "" }
        let from = bytes.index(bytes.startIndex, offsetBy: chapter.start)
        let to = bytes.index(bytes.startIndex, offsetBy: chapter.end)
        return String(bytes[from..<to]).map { Substring($0) } ?? ""
    }

    /// Findings the owner can mark that carry no mark yet: agreements,
    /// decided-alone items, blind spots, lens checks that raised a concern,
    /// and findings added from a thread.
    var unmarkedCount: Int {
        guard let result = row?.result else { return 0 }
        let keys = result.agreements.map(\.key) + result.decidedAlone.map(\.key)
            + result.blindSpots.map(\.key) + result.checks.filter { $0.answer == "concern" }.map(\.key)
            + threadFindings.map(\.key)
        return keys.filter { marks[$0] == nil }.count
    }

    /// Comment marks whose finding the re-run dropped; a finding added from
    /// a thread is no reviewer finding, but it is not gone either.
    var orphans: [SpecReviewMark] {
        guard let result = row?.result else { return [] }
        let added = Set(threadFindings.map(\.key))
        return SpecReviewAnswer.orphanMarks(result: result, marks: marks).filter { !added.contains($0.key) }
    }

    /// What the card under `key` is, for its buttons and its `ok` mark's
    /// label (spec 2026-11-08 §2): a finished loop's dispute, fix or
    /// unanswered finding; a finding added from a thread; an agreement the
    /// document matches; a check with a concern (fixable) or without one
    /// (to verify); a thesis. Anything else is a finding to act on. Nil for a
    /// check the reviewer found not applicable: it has no buttons at all
    /// (`SpecReviewPresentation.checkCardKind`).
    func cardKind(for key: String) -> SpecReviewCardKind? {
        if isLoop, let row {
            if SpecReviewLoop.disputed(row).contains(where: { $0.item.key == key }) { return .dispute }
            if SpecReviewLoop.unanswered(row).contains(where: { $0.item.key == key }) { return .unanswered }
            if SpecReviewLoop.fixed(row).contains(where: { $0.item.key == key }) { return .fixedByAuthor }
        }
        if threadFindings.contains(where: { $0.key == key }) { return .fromDiscussion }
        guard let result = row?.result else { return .actionable }
        if let agreement = result.agreements.first(where: { $0.key == key }) {
            return SpecReviewPresentation.cardKind(for: .agreement(agreement))
        }
        if let check = result.checks.first(where: { $0.key == key }) {
            return SpecReviewPresentation.checkCardKind(answer: check.answer)
        }
        if result.theses.contains(where: { $0.key == key }) { return .thesis }
        return .actionable
    }

    /// The document's Decisions list (spec §6), from the snapshot; nil when
    /// it has no Decisions section.
    var decisions: [String]? { SpecReviewDecisions.items(in: ask.docSnapshot) }

    /// A plan keeps no Decisions section (its agreements come from its
    /// spec), so Meaning shows the list for a spec only.
    var showsDecisions: Bool { ask.docType != "plan" }

    /// The ask's questions, answered on Meaning beside the findings.
    var hasQuestions: Bool { !ask.payload.questions.isEmpty }

    /// The reviewed document's file name, for the screen's title.
    var docName: String { (ask.docPath as NSString).lastPathComponent }

    /// The answer's note: the ask's draft note, shared with the classic
    /// view, so switching views keeps it.
    var note: String {
        get { asks.drafts.askDraft(for: ask.id).note }
        set { asks.editDraft(ask.id) { $0.note = newValue } }
    }

    /// An answer to the ask is being written: Send and Approve are off.
    var isAnswering: Bool { asks.isAnswering(ask.id) }

    // MARK: - Send and approve

    /// A **Fix** (a comment with no body) counts: it sends the finding.
    private var commentCount: Int {
        marks.values.filter { $0.state == .comment }.count
    }

    /// The ask's draft: the margin comments made under **Read the spec**,
    /// the question answers and the note, which go with the marks.
    private var draft: OwnerAskDraft { asks.drafts.askDraft(for: ask.id) }

    private var draftCommentCount: Int { draft.answer(for: ask).comments.count }

    /// N of **Request changes (N)**: every `comment` mark (Fix, Reviewer is
    /// right, Reopen, Comment) and every margin comment under Read the spec.
    var requestCount: Int { commentCount + draftCommentCount }

    /// Request changes — a new review round — needs something to change: a
    /// comment on a finding or in the margin, or the note (ask #690).
    var canSend: Bool {
        row != nil && (requestCount > 0 || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Approve is never off (ask #690): with comments the author applies
    /// them and goes on, with no new review round.
    var canApprove: Bool { true }

    /// Approve asks once when findings are still unmarked. A finished
    /// author loop's Approve is one press, except after an early end with
    /// a dispute nobody answered.
    var needsApproveConfirm: Bool {
        if reviewerUnfinished { return true }
        return isLoop ? endedEarly && unpickedDisputeCount > 0 : unmarkedCount > 0
    }

    /// The footer's Approve on the reviewer's status page: allowed, but
    /// asked once, since nothing has been reviewed yet.
    private var reviewerUnfinished: Bool { isReviewerActive && row?.result == nil && !isLoop }

    var approveConfirmMessage: String {
        if reviewerUnfinished { return "The reviewer has not finished — approve anyway?" }
        if isLoop {
            let n = unpickedDisputeCount
            return "\(n) disputed finding\(n == 1 ? " was" : "s were") never answered — approve anyway?"
        }
        return "\(unmarkedCount) finding\(unmarkedCount == 1 ? " is" : "s are") not marked. Approve anyway?"
    }

    /// What `verdict` hands to the ask's one answer path: the draft (margin
    /// comments, question answers, note) with the verdict. The marks'
    /// comments are added there, from the database (`SpecReviewAnswer`),
    /// as for the classic footer and the phone.
    func answer(verdict: OwnerAskAnswer.Verdict) -> OwnerAskAnswer {
        var answer = draft.answer(for: ask)
        answer.verdict = verdict
        return answer
    }

    /// Why Send and Approve are off, in the owner's words: the ask's
    /// questions are not all answered (they sit on Meaning), or the note is
    /// too long. Nil when the answer can go. Read on every Wrap-up body
    /// evaluation, so it checks the draft alone: the marks' comments always
    /// carry their finding's text, never a blank body, so they add no
    /// problem, and they are placed only when the answer is written.
    var answerBlocker: String? {
        var answer = draft.answer(for: ask)
        answer.verdict = .approved
        guard let problem = answer.problem(kind: ask.kind, payload: ask.payload) else { return nil }
        switch problem {
        case .questionUnanswered, .emptyQuestionAnswer: return "Answer the ask's questions on Meaning first"
        case .noteTooLong: return "Shorten the note to \(OwnerAskAnswerProblem.maxNoteRunes) characters"
        default: return "This answer cannot be sent: \(problem.message)"
        }
    }

    func send() async -> OwnerAsksViewModel.AnswerResult {
        guard canSend else {
            return .invalid("Comment on a finding, or write a note, before requesting changes.")
        }
        return await asks.answer(ask, with: answer(verdict: .changes))
    }

    func approve() async -> OwnerAsksViewModel.AnswerResult {
        await asks.answer(ask, with: answer(verdict: .approved))
    }

    /// The footer's Approve: asks first when `needsApproveConfirm`.
    func pressApprove() {
        guard canApprove, answerBlocker == nil, !isAnswering else { return }
        if needsApproveConfirm { confirmingApprove = true } else { Task { _ = await approve() } }
    }

    func pressRequestChanges() {
        guard canSend, answerBlocker == nil, !isAnswering else { return }
        Task { _ = await send() }
    }

    /// ⌘↩ / ⌘⇧↩ in the drawer while no text field has focus (a comment
    /// editor keeps ⌘↩ for itself: `OwnerAskKeyCatcher` stands aside).
    func pressKey(shift: Bool) {
        switch SpecReviewPresentation.keyVerdict(shift: shift, canSend: canSend, canApprove: canApprove) {
        case .changes: pressRequestChanges()
        case .approved: pressApprove()
        default: break
        }
    }
}

/// One Discuss thread as this screen holds it: whether it is drawn open,
/// and what its chat runs on once it was opened.
struct SpecReviewThreadState {
    var isOpen = false
    /// Its conversation and the reviewer's data are being fetched.
    var isOpening = false
    /// Opening failed (the conversation or `thread-context`); **Retry**
    /// opens it again.
    var loadError: String?
    var context: SpecReviewThreadContext?
    var conversationID: Int64?
}

// MARK: - Discuss threads (spec 2026-11-08 §3)

extension SpecReviewModel {
    /// The threads for the screen's environment; nil without the app's
    /// embedded chats (no **Discuss** then).
    var threads: SpecReviewThreads? {
        guard chats != nil else { return nil }
        return SpecReviewThreads(
            thread: { [self] in threadContent($0) },
            send: { [self] key, text in threadEngine(key)?.send(text) ?? false },
            open: { [self] in openThread($0) },
            hide: { [self] in threadStates[$0]?.isOpen = false },
            retry: { [self] in threadEngine($0)?.retry() },
            stop: { [self] in threadEngine($0)?.stop() }
        )
    }

    /// The thread's conversation key (`SpecReviewThreadKey`).
    func threadContextID(_ itemKey: String) -> String {
        SpecReviewThreadKey.contextID(workbenchID: ask.projectID, rootAskID: rootAskID, itemKey: itemKey)
    }

    /// Every item a thread can be about: the result's findings and checks,
    /// its theses, the loop's ledger and the findings added from a thread.
    var threadItemKeys: [String] {
        var keys = threadFindings.map(\.key) + (row?.ledger.map(\.item.key) ?? [])
        if let result = row?.result { keys += result.findings.map(\.key) + result.theses.map(\.key) }
        return keys
    }

    /// The item is gone after a re-run: its thread is readable only.
    func isOrphanedItem(_ key: String) -> Bool {
        !threadItemKeys.contains(key)
    }

    /// **Discuss** (or the folded line): the thread is drawn open, and on
    /// its first opening its conversation is found or created and the
    /// reviewer's data fetched (once; a failure shows **Retry**).
    func openThread(_ key: String) {
        guard chats != nil else { return }
        var state = threadStates[key] ?? SpecReviewThreadState()
        state.isOpen = true
        let needsPreparing = state.context == nil && !state.isOpening
        if needsPreparing {
            state.isOpening = true
            state.loadError = nil
        }
        threadStates[key] = state
        if needsPreparing { Task { await prepareThread(key) } }
    }

    private func prepareThread(_ key: String) async {
        let askID = ask.id
        let sessionID = ask.sessionID
        let workbenchID = ask.projectID
        do {
            let conversationID = try await SpecReviewThreadSurface.conversationID(
                workbenchID: workbenchID, rootAskID: rootAskID, itemKey: key, title: threadTitle(key), dbPool: dbPool)
            // An orphaned item's thread only shows what it holds: nothing to fetch.
            let orphaned = isOrphanedItem(key)
            let data = orphaned ? "" : try await cli.specReviewThreadContext(askID: askID, itemKey: key)
            let folders = try await dbPool.read { db in
                try SpecReviewThreadQueries.readFolders(db, sessionID: sessionID, workbenchID: workbenchID)
            }
            let context = SpecReviewThreadContext(
                workbenchID: workbenchID, rootAskID: rootAskID, askID: askID, itemKey: key, data: data,
                folder: SpecReviewThreadSurface.readFolder(sessionCwd: folders.sessionCwd,
                                                           workbenchFolder: folders.workbenchFolder),
                provider: configuredProvider(),
                // The chat outlives this screen in the app's center: once the
                // screen is gone, the item stands as it was when opened.
                isOrphaned: { [weak self] in self?.isOrphanedItem(key) ?? orphaned },
                onReply: { [weak self] question, finding in
                    self?.threadReplied(key: key, question: question, finding: finding)
                }
            )
            threadStates[key, default: SpecReviewThreadState()].context = context
            threadStates[key]?.conversationID = conversationID
            threadStates[key]?.isOpening = false
            _ = threadEngine(key)
        } catch {
            threadStates[key, default: SpecReviewThreadState()].isOpening = false
            threadStates[key]?.loadError = "Couldn't open the discussion: \(error.localizedDescription)"
        }
    }

    /// The thread's chat once it was opened, from the app's center (created
    /// again there if the idle sweep let it go).
    func threadEngine(_ key: String) -> EmbeddedChatEngine? {
        guard let chats, let state = threadStates[key], let context = state.context,
              let conversationID = state.conversationID else { return nil }
        return chats.engine(for: SpecReviewThreadSurface.spec(context: context, conversationID: conversationID,
                                                              dbPool: dbPool))
    }

    /// A completed thread reply's blocks: a question for the author, a
    /// proposed finding. The proposal is shown from the stored reply; the
    /// question's row and the message count are read again once the reply
    /// is saved (this runs before the engine's final write).
    func threadReplied(key: String, question: String?, finding: SpecReviewProposedFinding?) {
        let engine = threadEngine(key)
        Task {
            await engine?.finished()
            await loadThreads()
        }
    }

    /// Reads the threads' questions and message counts for every item on
    /// the screen.
    func loadThreads() async {
        let byContext = Dictionary(threadItemKeys.map { (threadContextID($0), $0) }) { first, _ in first }
        let contextIDs = Array(byContext.keys)
        do {
            let (questions, counts) = try await dbPool.read { db in
                (try SpecReviewThreadQueries.questions(db, threads: contextIDs),
                 try SpecReviewThreadQueries.messageCounts(db, contextIDs: contextIDs))
            }
            var byKey: [String: Int] = [:]
            for (contextID, count) in counts { if let key = byContext[contextID] { byKey[key] = count } }
            if questions != threadQuestions { threadQuestions = questions }
            if byKey != threadMessageCounts { threadMessageCounts = byKey }
        } catch {
            lastError = "Could not read the discussions: \(error.localizedDescription)"
        }
    }

    /// What `key`'s thread shows.
    func threadContent(_ key: String) -> SpecReviewThreadContent {
        var content = SpecReviewThreadContent()
        content.isOrphaned = isOrphanedItem(key)
        content.persistedMessageCount = threadMessageCounts[key] ?? 0
        guard let state = threadStates[key] else { return content }
        content.isOpen = state.isOpen
        content.isOpening = state.isOpening
        content.loadError = state.loadError
        guard let engine = threadEngine(key) else { return content }
        content.isQueued = engine.isQueued
        content.isReplying = engine.isBusy
        let contextID = threadContextID(key)
        let retryID = engine.canRetry && !engine.isBusy
            ? engine.messages.last { $0.message.role == "assistant" }?.id : nil
        content.entries = Self.threadEntries(
            messages: engine.messages.map(\.message),
            liveText: { engine.liveTurn?.messageID == $0 ? engine.liveTurn?.text : nil },
            questions: threadQuestions.filter { $0.thread == contextID },
            retryID: retryID
        )
        return content
    }

    /// A thread's rows in order: the owner's words, the assistant's replies
    /// with their blocks taken out (the running one with an open block
    /// hidden), each reply's proposed finding and its question to the
    /// author (the question's row, matched by its text; rows no reply names
    /// come last), Watchtower's lines and failed replies.
    static func threadEntries(
        messages: [ChatMessageRecord],
        liveText: (Int64) -> String?,
        questions: [SpecReviewQuestionRow],
        retryID: Int64?
    ) -> [SpecReviewThreadEntry] {
        var remaining = questions
        var out: [SpecReviewThreadEntry] = []
        for message in messages {
            let id = "m\(message.id)"
            switch message.role {
            case "user":
                out.append(.owner(id: id, text: message.text))
            case "system":
                out.append(.notice(id: id, text: message.text))
            case "assistant":
                if let live = liveText(message.id) {
                    let text = SpecReviewThreadBlocks.parse(live, final: false).text
                    if !text.isEmpty { out.append(.assistant(id: id, text: text)) }
                } else if message.status == "error" || (message.status == "partial" && message.id == retryID) {
                    // A partial row offered Retry is a reply whose error
                    // could not be written over it.
                    let failed = message.status == "error"
                    out.append(.failed(
                        id: id,
                        message: failed ? ChatErrorPresentation.message(for: message.errorCode, provider: message.provider)
                            : "The reply was not saved.",
                        detail: ChatErrorPresentation.detail(message.errorMessage),
                        canRetry: message.id == retryID && (!failed || ChatErrorPresentation.isRetryable(message.errorCode))
                    ))
                } else {
                    // A stopped reply is never read for blocks.
                    let blocks = SpecReviewThreadBlocks.parse(message.text, final: message.status == "complete")
                    if !blocks.text.isEmpty { out.append(.assistant(id: id, text: blocks.text)) }
                    if let finding = blocks.finding { out.append(.finding(id: "f\(message.id)", finding)) }
                    if let question = blocks.question, let index = remaining.firstIndex(where: { $0.question == question }) {
                        out.append(.question(remaining.remove(at: index)))
                    }
                }
            default:
                break
            }
        }
        return out + remaining.map { .question($0) }
    }

    /// The thread's conversation title: the item's own line.
    private func threadTitle(_ key: String) -> String {
        if let finding = row?.result?.findings.first(where: { $0.key == key }) { return finding.text }
        if let thesis = row?.result?.theses.first(where: { $0.key == key }) { return thesis.text }
        if let entry = row?.ledger.first(where: { $0.item.key == key }) { return entry.item.text }
        return threadFindings.first { $0.key == key }?.headline ?? key
    }
}
