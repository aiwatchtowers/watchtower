import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The spec review screen's presentation (spec 2026-10-25 §7): counts and
/// status lines, badges, source labels, Wrap-up groups, Meaning's notes,
/// the drawer's switch between the screen and the classic view, and the
/// phase picker shared with Deep review.
@MainActor
final class SpecReviewViewTests: XCTestCase {
    private var fixtures: [ReviewFixture] = []
    private var paths: [String] = []

    override func tearDown() {
        fixtures.forEach { $0.cleanUp() }
        fixtures = []
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    private func result(_ json: String) throws -> SpecReviewResult {
        try JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8))
    }

    private func row(status: String, reason: String = "", model: String = "", result: String = "", dropped: Int = 0) -> SpecReviewRow? {
        try? SpecReviewRow(row: Row([
            "ask_id": 1, "status": status, "reason": reason, "provider": "", "model": model,
            "dropped": dropped, "attempt": 1, "result": result
        ]))
    }

    private func agreements(_ statuses: [String]) -> String {
        statuses.enumerated()
            .map { #"{"key":"ag:\#($0.offset)","text":"t\#($0.offset)","status":"\#($0.element)"}"# }
            .joined(separator: ",")
    }

    func testCountsLine() throws {
        let statuses = Array(repeating: "as_agreed", count: 9) + ["differs", "missing"]
        let full = try result("""
        {"agreements":[\(agreements(statuses))],
         "decided_alone":[{"key":"da:1"},{"key":"da:2"},{"key":"da:3"},{"key":"da:4"}],
         "blind_spots":[{"key":"bs:1"},{"key":"bs:2"}]}
        """)
        XCTAssertEqual(SpecReviewPresentation.countsLine(full),
                       "9 as agreed · 1 differs · 1 missing · 4 decided alone · 2 blind spots")
        let one = try result(#"{"agreements":[\#(agreements(["as_agreed", "odd"]))],"blind_spots":[{"key":"bs:1"}]}"#)
        XCTAssertEqual(SpecReviewPresentation.countsLine(one), "1 as agreed · 1 other · 1 blind spot",
                       "zero counts are left out; an unknown status counts as other")
        XCTAssertEqual(SpecReviewPresentation.countsLine(try result("{}")), "No findings")
    }

    func testStatusLines() {
        XCTAssertNil(SpecReviewPresentation.statusLine(nil))
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "running")),
                       "Reviewer is reading the spec and the discussion…")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "queued")), "Reviewer is waiting to start…")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "failed", reason: "timed out")),
                       "Reviewer failed: timed out")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "failed")), "Reviewer failed")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "skipped", reason: "plan near limit")),
                       "Reviewer skipped: plan near limit")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "done", model: "opus", result: "{}")),
                       "Reviewer finished · opus")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "done", result: "not json")),
                       "The reviewer's result could not be read")
        XCTAssertEqual(SpecReviewPresentation.statusLine(row(status: "bogus")),
                       "Reviewer state is not known to this version of the app")
    }

    func testDrawerModeLoopOwnerIsReview() throws {
        typealias Pres = SpecReviewPresentation
        func loopRow(status: String, loop: String) throws -> SpecReviewRow {
            try SpecReviewRow(row: Row([
                "ask_id": 1, "status": status, "reason": "", "provider": "", "model": "",
                "dropped": 0, "attempt": 1, "result": "", "loop": loop, "loop_end": "reviewer_failed"
            ]))
        }
        XCTAssertEqual(Pres.drawerMode(row: try loopRow(status: "failed", loop: "owner"), showClassic: false), .review,
                       "a finished loop has its screen whatever the reviewer's last status")
        XCTAssertEqual(Pres.drawerMode(row: try loopRow(status: "done", loop: "owner"), showClassic: true), .classic(.banner))
        XCTAssertEqual(Pres.drawerMode(row: try loopRow(status: "failed", loop: "author"), showClassic: false), .classic(.status))
    }

    func testGoToMeaningOnlyWhenMeaningHasAResult() throws {
        typealias Pres = SpecReviewPresentation
        func loopRow(status: String, result: String) throws -> SpecReviewRow {
            try SpecReviewRow(row: Row([
                "ask_id": 1, "status": status, "reason": "", "provider": "", "model": "",
                "dropped": 0, "attempt": 1, "result": result, "loop": "owner", "loop_end": "reviewer_failed"
            ]))
        }
        let done = try loopRow(status: "done", result: "{}")
        XCTAssertTrue(Pres.showsGoToMeaning(row: done, hasQuestions: true))
        XCTAssertFalse(Pres.showsGoToMeaning(row: done, hasQuestions: false))
        XCTAssertFalse(Pres.showsGoToMeaning(row: try loopRow(status: "failed", result: ""), hasQuestions: true),
                       "a loop whose reviewer failed has no Meaning to go to")
        XCTAssertFalse(Pres.showsGoToMeaning(row: nil, hasQuestions: true))
    }

    func testLoopDisputeAndFixLines() throws {
        typealias Pres = SpecReviewPresentation
        let entries = try JSONDecoder().decode([SpecReviewLedgerEntry].self, from: Data("""
        [{"key":"a","text":"t","note":"own","reply":{"reply":"disagree","note":"no"},"verdict":"disputed","verdict_note":"still","settled":2},
         {"key":"b","text":"t","note":"own","reply":{"reply":"disagree","note":"no"},"verdict":"unsettled","verdict_note":"no","settled":3},
         {"key":"c","text":"t","note":"","round":1,"verdict":"unsettled","verdict_note":"The author did not answer"},
         {"key":"d","text":"t","round":1,"reply":{"reply":"fixed","note":""},"verdict":"resolved","settled":2}]
        """.utf8))
        XCTAssertEqual(Pres.reviewerPosition(entries[0]), "still")
        XCTAssertEqual(Pres.authorReason(entries[0]), "no")
        XCTAssertEqual(Pres.reviewerPosition(entries[1]), "own", "an early end copied the author's reason")
        XCTAssertNil(Pres.reviewerPosition(entries[2]), "a loop-end line is never the reviewer's argument")
        XCTAssertEqual(Pres.loopStatus(entries[2]), "The author did not answer")
        XCTAssertNil(Pres.loopStatus(entries[0]), "a dispute has no loop-end line")
        XCTAssertNil(Pres.loopStatus(entries[1]), "the author's reason is not repeated")
        XCTAssertNil(Pres.authorReason(entries[2]))
        XCTAssertEqual(Pres.loopBadge(entries[0]).title, "Disputed")
        XCTAssertEqual(Pres.loopBadge(entries[1]).title, "Not settled")
        XCTAssertEqual(Pres.loopBadge(entries[2]).title, "New in round 1")
        XCTAssertEqual(Pres.fixRound(entries[3]), "Round 2")
        XCTAssertEqual(Pres.fixNote(entries[3]), "no note")
        XCTAssertEqual(Pres.nextStep(.chapters, loop: true)?.phase, .wrapup)
        XCTAssertNil(Pres.nextStep(.wrapup, loop: true))
    }

    /// Review focus: a review that finishes while the classic view is open
    /// offers a banner and never replaces the view; a failed or skipped one
    /// keeps the classic view under its reason.
    func testDrawerModes() {
        typealias Pres = SpecReviewPresentation
        let done = row(status: "done", result: "{}")
        XCTAssertEqual(Pres.drawerMode(row: nil, showClassic: false), .classic(nil))
        // Before the first load returns nothing shows, so the classic view never flashes first.
        XCTAssertEqual(Pres.drawerMode(row: nil, showClassic: false, loaded: false), .loading)
        XCTAssertEqual(Pres.drawerMode(row: done, showClassic: false, loaded: false), .loading)
        XCTAssertEqual(Pres.drawerMode(row: done, showClassic: false), .review)
        XCTAssertEqual(Pres.drawerMode(row: done, showClassic: true), .classic(.banner))
        XCTAssertEqual(Pres.drawerMode(row: row(status: "running"), showClassic: false), .review)
        XCTAssertEqual(Pres.drawerMode(row: row(status: "queued"), showClassic: true), .classic(.status))
        XCTAssertEqual(Pres.drawerMode(row: row(status: "failed"), showClassic: false), .classic(.status))
        XCTAssertEqual(Pres.drawerMode(row: row(status: "skipped"), showClassic: false), .classic(.status))
        XCTAssertEqual(Pres.drawerMode(row: row(status: "done", result: "not json"), showClassic: false), .classic(.status))
        XCTAssertEqual(Pres.drawerMode(row: row(status: "bogus"), showClassic: false), .classic(.status))
    }

    func testBadges() throws {
        let r = try result("""
        {"agreements":[\(agreements(["as_agreed", "differs", "missing", "odd"]))],
         "decided_alone":[{"key":"da:1"}],"blind_spots":[{"key":"bs:1"}]}
        """)
        let badges = r.agreements.map { SpecReviewPresentation.badge(for: .agreement($0)) }
        XCTAssertEqual(badges.map(\.title), ["As agreed", "Differs", "Missing", "odd"])
        XCTAssertEqual(badges.map(\.tint), [.success, .neutral, .neutral, .neutral], "only severity is coloured")
        XCTAssertEqual(SpecReviewPresentation.badge(for: .decidedAlone(r.decidedAlone[0])).title, "Decided alone")
        XCTAssertEqual(SpecReviewPresentation.badge(for: .blindSpot(r.blindSpots[0])).title, "Blind spot")

        let chapter = SpecReviewChapterVM(
            key: "ch:1", heading: "Behaviour", excerpt: "",
            findings: r.agreements.map { .agreement($0) } + [.blindSpot(r.blindSpots[0])],
            checks: try result(#"{"checks":[{"key":"ck:1","answer":"concern"},{"key":"ck:2","answer":"ok"}]}"#).checks,
            viewed: false
        )
        let row = SpecReviewPresentation.chapterBadges(chapter)
        XCTAssertEqual(row.map { "\($0.count) \($0.badge.title)" }, ["1 Differs", "1 Missing", "1 odd", "1 Blind spot", "1 Concern"],
                       "As agreed gets no badge on the chapter row")
    }

    /// Only the owner's own words are "What you said"; an agent's line is
    /// named by where it came from.
    func testSourceLabelOnlyClaimsOwnerWords() throws {
        func source(_ kind: String, _ speaker: String, ref: String = "") throws -> SpecReviewResult.Source {
            let json = #"{"agreements":[{"key":"a","source":{"kind":"\#(kind)","ref":"\#(ref)","speaker":"\#(speaker)"}}]}"#
            return try XCTUnwrap(try result(json).agreements[0].source)
        }
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("ask", "owner", ref: "ask:571")), "What you said · ask #571")
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("conversation", "owner", ref: "entry:3")), "What you said")
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("conversation", "agent")), "The agent said")
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("decisions", "agent")), "Decisions")
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("spec", "")), "Spec")
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("target", "agent", ref: "target:12")), "Target · target #12")
        XCTAssertEqual(SpecReviewPresentation.sourceLabel(try source("ask", "agent", ref: "ask:4")), "Ask · ask #4")

        func idea(_ kind: String, _ speaker: String) throws -> SpecReviewResult.Idea {
            let json = #"{"idea":{"owner_quote":"mute a channel","owner_source":{"kind":"\#(kind)","speaker":"\#(speaker)"}}}"#
            return try XCTUnwrap(try result(json).idea)
        }
        let owner = try idea("conversation", "owner")
        XCTAssertEqual(SpecReviewPresentation.ideaLabel(owner), "Your idea")
        let agent = try idea("decisions", "agent")
        XCTAssertEqual(SpecReviewPresentation.ideaLabel(agent), "The idea · Decisions")
    }

    func testWrapUpGroups() throws {
        let r = try result("""
        {"agreements":[\(agreements(["missing", "as_agreed", "odd"]))],
         "decided_alone":[{"key":"da:1","text":"Local db"}],
         "checks":[{"key":"ck:1","question":"q?","answer":"concern"},{"key":"ck:2","answer":"ok"}]}
        """)
        let groups = SpecReviewPresentation.wrapUpGroups(r)
        XCTAssertEqual(groups.map(\.title), ["As agreed", "Missing", "Other", "Decided alone", "Concerns"],
                       "empty groups are left out")
        XCTAssertEqual(groups.map { $0.items.map(\.key) }, [["ag:1"], ["ag:0"], ["ag:2"], ["da:1"], ["ck:1"]])
    }

    func testMeaningNotes() throws {
        let r = try result(#"{"notes":["The conversation was trimmed."],"code_read":false,"dropped":2}"#)
        XCTAssertEqual(SpecReviewPresentation.notes(row: nil, result: r), [
            "The conversation was trimmed.",
            "2 findings were dropped: the quote was not found in its source.",
            "The reviewer did not read the code."
        ])
        let clean = try result(#"{"code_read":true}"#)
        XCTAssertEqual(SpecReviewPresentation.notes(row: row(status: "done", dropped: 1), result: clean),
                       ["1 finding was dropped: the quote was not found in its source."])
    }

    /// Deep review's strip is the shared picker over its model: the same
    /// three titles and its own progress line.
    func testPhasePickerKeepsDeepReviewBehaviour() async throws {
        XCTAssertEqual(ReviewPhasePicker.titles, [.meaning: "1 Meaning", .chapters: "2 Chapters", .wrapup: "3 Wrap-up"])
        let fixture = try ReviewFixture(files: [.init(path: "a.go")], mode: "deep", phase: "chapters")
        fixtures.append(fixture)
        await fixture.open()
        let picker = try ReviewPhaseStrip(model: fixture.model).inspect().find(ReviewPhasePicker.self)
        XCTAssertEqual(try picker.actualView().progress, ReviewToolbar.progressLine(fixture.model))
        XCTAssertEqual(try picker.actualView().phase, .chapters)
        XCTAssertNoThrow(try picker.find(text: ReviewToolbar.progressLine(fixture.model)))

        var phase = ReviewPhase.meaning
        let shared = ReviewPhasePicker(phase: Binding(get: { phase }, set: { phase = $0 }), progress: "")
        shared.phase = .wrapup
        XCTAssertEqual(phase, .wrapup)
    }

    /// Review focus: Send is off until a finding carries a comment, and
    /// Approve with unmarked findings asks first.
    /// A review ask on a test database with a spec review row, and its loaded model.
    private func makeModel(status: String, result: String) async throws -> SpecReviewModel {
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let (projectID, askID) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d, folder: NSTemporaryDirectory())
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p, kind: "review", docPath: "spec.md")
            try d.execute(sql: "UPDATE owner_asks SET doc_snapshot = '# T\nx\n' WHERE id = ?", arguments: [id])
            try d.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, result, queued_at) VALUES (?, ?, ?, '2026-10-25T10:00:00Z')
                """, arguments: [id, status, result])
            return (p, id)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpecReviewViewTests-\(UUID().uuidString)"))
        let asks = OwnerAsksViewModel(dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil),
                                      defaults: defaults)
        await asks.load(projectID: projectID)
        let ask = try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID })
        let model = SpecReviewModel(ask: ask, dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), asks: asks)
        await model.load()
        return model
    }

    func testAppliesOnlyToOpenSpecAndPlanReviews() {
        typealias Pres = SpecReviewPresentation
        XCTAssertTrue(Pres.applies(kind: .review, docType: "spec", isOpen: true, hasCLI: true))
        XCTAssertTrue(Pres.applies(kind: .review, docType: "plan", isOpen: true, hasCLI: true))
        XCTAssertFalse(Pres.applies(kind: .review, docType: "other", isOpen: true, hasCLI: true), "never waits for a review that cannot come")
        XCTAssertFalse(Pres.applies(kind: .review, docType: "", isOpen: true, hasCLI: true))
        XCTAssertFalse(Pres.applies(kind: .review, docType: "spec", isOpen: false, hasCLI: true))
        XCTAssertFalse(Pres.applies(kind: .review, docType: "spec", isOpen: true, hasCLI: false))
        XCTAssertFalse(Pres.applies(kind: .check, docType: "spec", isOpen: true, hasCLI: true))
    }

    /// The running page offers Read the spec once: the header's.
    func testRunningPageHasOneReadTheSpec() async throws {
        let model = try await makeModel(status: "running", result: "")
        let buttons = try SpecReviewView(model: model) {}.inspect().findAll(ViewType.Button.self)
        let titles = try buttons.map { try $0.labelView().text().string() }
        XCTAssertEqual(titles.filter { $0 == "Read the spec" }.count, 1)
        XCTAssertFalse(titles.contains("Re-run reviewer"), "no Re-run while the reviewer runs")
    }

    /// Under the spec review screen only the keys that write the classic
    /// draft stand aside; J / K and the cursor keys still move.
    func testDraftKeysOnlyAreOffUnderTheScreen() {
        XCTAssertTrue(OwnerAskDrawerKeys.writesDraft(.choose(0)))
        XCTAssertTrue(OwnerAskDrawerKeys.writesDraft(.edit))
        for action: OwnerAskKeyMap.Action in [.nextAsk, .previousAsk, .nextStop, .previousStop, .nextComment, .previousComment] {
            XCTAssertFalse(OwnerAskDrawerKeys.writesDraft(action), "\(action) is navigation")
        }
    }

    /// The footer's verdicts (spec 2026-10-28 §5): Request changes needs a
    /// comment and shows N; Approve is off while one would go back; the
    /// body of Wrap-up carries no verdict button any more.
    func testFooterVerdictsRequestChangesAndApprove() async throws {
        let model = try await makeModel(
            status: "done",
            result: #"{"agreements":[{"key":"ag:1","text":"t","status":"differs"},{"key":"ag:2","text":"u","status":"missing"}]}"#
        )
        let result = try XCTUnwrap(model.row?.result)
        func button(_ title: String) throws -> InspectableView<ViewType.Button> {
            try SpecReviewVerdictButtons(model: model).inspect().find(button: title)
        }
        XCTAssertTrue(try button("Request changes").isDisabled())
        XCTAssertFalse(try button("Approve").isDisabled())
        XCTAssertTrue(model.needsApproveConfirm)
        XCTAssertEqual(model.approveConfirmMessage, "2 findings are not marked. Approve anyway?")

        await model.mark("ag:1", .comment, body: "Keep it as agreed.")
        XCTAssertFalse(try button("Request changes (1)").isDisabled())
        XCTAssertTrue(try button("Approve").isDisabled())
        await model.mark("ag:2", .ok)
        XCTAssertFalse(model.needsApproveConfirm, "every finding marked: Approve goes straight through")

        let wrapUp = try SpecReviewWrapUpView(model: model, result: result).inspect()
        XCTAssertThrowsError(try wrapUp.find(button: "Approve"), "no verdict in Wrap-up's body")
        XCTAssertThrowsError(try wrapUp.find(button: "Send round to the author"))
    }

    /// ⌘↩ approves, ⌘⇧↩ requests changes, each only while its button is
    /// on. A focused comment editor never sees them here: the key catcher
    /// stands aside for an editable text view (`OwnerAskKeyCatcher`), and
    /// the editor's own ⌘↩ saves the comment.
    func testKeyVerdicts() {
        typealias Pres = SpecReviewPresentation
        XCTAssertEqual(Pres.keyVerdict(shift: false, canSend: false, canApprove: true), .approved)
        XCTAssertNil(Pres.keyVerdict(shift: false, canSend: true, canApprove: false))
        XCTAssertEqual(Pres.keyVerdict(shift: true, canSend: true, canApprove: false), .changes)
        XCTAssertNil(Pres.keyVerdict(shift: true, canSend: false, canApprove: true))
    }

    /// Colour is severity (spec 2026-10-28 §2): Blocker red, Major orange,
    /// Minor grey; kinds and loop states are grey; findings sort by
    /// severity, stable within a level; the counts line leads with it.
    func testSeverityChipsSortAndCounts() throws {
        typealias Pres = SpecReviewPresentation
        XCTAssertEqual(Pres.severityBadge(.blocker), .init(title: "Blocker", tint: .error))
        XCTAssertEqual(Pres.severityBadge(.major), .init(title: "Major", tint: .warning))
        XCTAssertEqual(Pres.severityBadge(.minor), .init(title: "Minor", tint: .neutral))
        XCTAssertNil(Pres.severityBadge(nil))

        let r = try result("""
        {"agreements":[{"key":"ag:1","status":"differs","severity":"minor"},{"key":"ag:2","status":"as_agreed"}],
         "decided_alone":[{"key":"da:1","severity":" Major "}],
         "blind_spots":[{"key":"bs:1","severity":"blocker"},{"key":"bs:2","severity":"huge"},{"key":"bs:3","severity":"blocker"}],
         "checks":[{"key":"ck:1","answer":"concern","severity":"major"}]}
        """)
        XCTAssertEqual(r.decidedAlone[0].severity, .major, "trimmed and lower-cased")
        XCTAssertNil(r.blindSpots[1].severity, "an unknown level is none")
        let findings: [SpecReviewChapterFinding] = r.agreements.map { .agreement($0) }
            + r.decidedAlone.map { .decidedAlone($0) } + r.blindSpots.map { .blindSpot($0) }
        XCTAssertEqual(Pres.sortedBySeverity(findings, \.severity).map(\.key), ["bs:1", "bs:3", "da:1", "ag:1", "ag:2", "bs:2"])
        XCTAssertEqual(Pres.severityCounts(r), "2 blockers · 2 major · 1 minor")
        XCTAssertTrue(Pres.countsLine(r).hasPrefix("2 blockers · 2 major · 1 minor — 1 as agreed"))
        XCTAssertNil(Pres.severityCounts(try result(#"{"blind_spots":[{"key":"bs:1"}]}"#)), "an old review has no severities")
        XCTAssertEqual(Pres.countsLine(try result(#"{"blind_spots":[{"key":"bs:1"}]}"#)), "1 blind spot")
        XCTAssertEqual(Pres.badge(for: .decidedAlone(r.decidedAlone[0])).tint, .neutral, "Decided alone is never blue")
    }

    func testLoopItemKeepsSeverityAndAGreyChip() throws {
        let entries = try JSONDecoder().decode([SpecReviewLedgerEntry].self, from: Data("""
        [{"key":"bs:1","kind":"blind_spot","text":"t","round":3,"severity":"blocker","verdict":"unsettled"},
         {"key":"ck:1","kind":"check","text":"t","round":2,"verdict":"disputed"}]
        """.utf8))
        XCTAssertEqual(entries[0].item.severity, .blocker)
        XCTAssertNil(entries[1].item.severity, "a ledger without severity decodes")
        XCTAssertEqual(SpecReviewPresentation.loopBadge(entries[0]), .init(title: "Blind spot · New in round 3", tint: .neutral))
        XCTAssertEqual(SpecReviewPresentation.loopBadge(entries[1]).title, "Concern · Disputed")
    }
}
