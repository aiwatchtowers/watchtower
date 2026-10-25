import Foundation
import Observation
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

    @ObservationIgnored private let ask: OwnerAsk
    @ObservationIgnored private let db: DatabaseManager
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
        db: DatabaseManager,
        cli: WorkbenchCLI,
        asks: OwnerAsksViewModel,
        pollInterval: Duration = .seconds(3),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.ask = ask
        self.db = db
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
            let (row, marks) = try await db.dbPool.read { db in
                (try SpecReviewQueries.row(db, askID: askID), try SpecReviewQueries.marks(db, askID: askID))
            }
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

    func mark(_ key: String, _ state: SpecReviewMarkState, body: String = "") async {
        let askID = ask.id
        let mark = SpecReviewMark(key: key, state: state, body: body)
        let stamp = now()
        do {
            try await db.dbPool.write { db in
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
            try await db.dbPool.write { db in
                try SpecReviewQueries.clearMark(db, askID: askID, key: key)
            }
            marks[key] = nil
        } catch {
            lastError = "Could not clear the mark: \(error.localizedDescription)"
        }
    }

    // MARK: - Derived screen state

    var chapters: [SpecReviewChapterVM] {
        guard let result = row?.result else { return [] }
        let known = Set(result.chapters.map(\.key))
        func inChapter(_ key: String) -> Bool { known.contains(key) }
        func findings(_ pick: (String) -> Bool) -> [SpecReviewChapterFinding] {
            result.agreements.filter { pick($0.chapter) }.map { .agreement($0) }
                + result.decidedAlone.filter { pick($0.chapter) }.map { .decidedAlone($0) }
                + result.blindSpots.filter { pick($0.chapter) }.map { .blindSpot($0) }
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

    // MARK: - Send and approve

    private var commentCount: Int {
        marks.values.filter {
            $0.state == .comment && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    /// Send round to the author needs at least one comment.
    var canSend: Bool { row?.result != nil && commentCount > 0 }

    /// Approve asks once when findings are still unmarked.
    var needsApproveConfirm: Bool { unmarkedCount > 0 }

    var approveConfirmMessage: String {
        "\(unmarkedCount) finding\(unmarkedCount == 1 ? " is" : "s are") not marked. Approve anyway?"
    }

    func send(note: String) async -> OwnerAsksViewModel.AnswerResult {
        guard canSend, let result = row?.result else {
            return .invalid("Comment on at least one finding before sending the round.")
        }
        return await asks.answer(ask, with: SpecReviewAnswer.build(
            result: result, marks: marks, note: note, verdict: .changes, snapshot: ask.docSnapshot
        ))
    }

    func approve(note: String) async -> OwnerAsksViewModel.AnswerResult {
        let result = row?.result ?? Self.emptyResult
        return await asks.answer(ask, with: SpecReviewAnswer.build(
            result: result, marks: marks, note: note, verdict: .approved, snapshot: ask.docSnapshot
        ))
    }

    private static let emptyResult: SpecReviewResult = {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(SpecReviewResult.self, from: Data("{}".utf8))
    }()
}
