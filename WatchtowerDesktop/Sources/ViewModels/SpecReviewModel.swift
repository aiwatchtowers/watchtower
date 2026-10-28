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

    var key: String {
        switch self {
        case let .agreement(f): f.key
        case let .decidedAlone(f): f.key
        case let .blindSpot(f): f.key
        }
    }

    var severity: SpecReviewSeverity? {
        switch self {
        case let .agreement(f): f.severity
        case let .decidedAlone(f): f.severity
        case let .blindSpot(f): f.severity
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
    var phase: ReviewPhase = .meaning
    var chapterKey: String?
    var lastError: String?
    /// The footer's Approve asked to confirm (unmarked findings, or an
    /// unanswered dispute after an early end).
    var confirmingApprove = false

    @ObservationIgnored let ask: OwnerAsk
    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let cli: WorkbenchCLI
    @ObservationIgnored private let asks: OwnerAsksViewModel
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
        pollInterval: Duration = .seconds(3),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.ask = ask
        self.dbPool = dbPool
        self.cli = cli
        self.asks = asks
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    deinit { pollTask?.cancel() }

    // MARK: - Loading and polling

    func load() async {
        let askID = ask.id
        do {
            let (row, marks) = try await dbPool.read { db in
                (try SpecReviewQueries.row(db, askID: askID), try SpecReviewQueries.marks(db, askID: askID))
            }
            // A finished author loop opens on its disputes (spec 2026-10-26 §6).
            if self.row == nil, row?.loop == .owner { phase = .wrapup }
            self.row = row
            self.marks = marks
            if chapterKey == nil || !chapters.contains(where: { $0.key == chapterKey }) {
                chapterKey = chapters.first?.key
            }
        } catch {
            lastError = "Could not read the spec review: \(error.localizedDescription)"
        }
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
        func findings(_ pick: (String) -> Bool) -> [SpecReviewChapterFinding] {
            SpecReviewPresentation.sortedBySeverity(
                result.agreements.filter { pick($0.chapter) }.map { .agreement($0) }
                    + result.decidedAlone.filter { pick($0.chapter) }.map { .decidedAlone($0) }
                    + result.blindSpots.filter { pick($0.chapter) }.map { .blindSpot($0) },
                \.severity
            )
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
    /// decided-alone items, blind spots, and lens checks that raised a concern.
    var unmarkedCount: Int {
        guard let result = row?.result else { return 0 }
        let keys = result.agreements.map(\.key) + result.decidedAlone.map(\.key)
            + result.blindSpots.map(\.key) + result.checks.filter { $0.answer == "concern" }.map(\.key)
        return keys.filter { marks[$0] == nil }.count
    }

    var orphans: [SpecReviewMark] {
        guard let result = row?.result else { return [] }
        return SpecReviewAnswer.orphanMarks(result: result, marks: marks)
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

    /// Request changes needs at least one comment, on a finding or in the
    /// margin.
    var canSend: Bool { row != nil && requestCount > 0 }

    /// Approve is for "nothing to send back" (spec 2026-10-28 D7): off
    /// while a comment would go to the author.
    var canApprove: Bool { requestCount == 0 }

    /// Approve asks once when findings are still unmarked. A finished
    /// author loop's Approve is one press, except after an early end with
    /// a dispute nobody answered.
    var needsApproveConfirm: Bool {
        isLoop ? endedEarly && unpickedDisputeCount > 0 : unmarkedCount > 0
    }

    var approveConfirmMessage: String {
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
            return .invalid("Comment on at least one finding before sending the round.")
        }
        return await asks.answer(ask, with: answer(verdict: .changes))
    }

    func approve() async -> OwnerAsksViewModel.AnswerResult {
        guard canApprove else {
            return .invalid("Remove your comments for the author to approve, or Request changes.")
        }
        return await asks.answer(ask, with: answer(verdict: .approved))
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
