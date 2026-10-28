import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class SpecReviewTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spec_review_result.json")
        return try Data(contentsOf: url)
    }

    private func golden() throws -> SpecReviewResult {
        try JSONDecoder().decode(SpecReviewResult.self, from: fixtureData())
    }

    private let snapshot = "# Title\nIntro text\n## Behaviour\nMuting lasts twenty-four hours\nMore\n"
        + "## Decisions\nMute state lives in the local database\n"

    private func chapterized(_ result: SpecReviewResult) -> SpecReviewResult {
        // Real offsets into `snapshot` (UTF-8 bytes).
        let behaviour = snapshot.utf8.count - "## Decisions\nMute state lives in the local database\n".utf8.count
        let json = """
        {"chapters":[{"key":"ch:0","heading":"Title","start":0,"end":19},
        {"key":"ch:1","heading":"Behaviour","start":19,"end":\(behaviour)}]}
        """
        var out = result
        out.chapters = (try? JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8)).chapters) ?? []
        return out
    }

    func testDecodesPlan1Golden() throws {
        let r = try golden()
        XCTAssertEqual(r.summary, "The spec matches the idea; one promise has no task.")
        XCTAssertEqual(r.idea?.verdict, "matches")
        XCTAssertEqual(r.agreements.first?.key, "ag:0123456789ab")
        XCTAssertEqual(r.agreements.first?.anchor, .init(heading: "Behaviour", quote: "Muting lasts twenty-four hours"))
        XCTAssertEqual(r.idea?.ownerSource?.speaker, "owner")
        XCTAssertEqual(r.agreements.first?.source?.speaker, "owner")
        XCTAssertEqual(r.decidedAlone.first?.chapter, "ch:2")
        XCTAssertEqual(r.blindSpots.first?.evidence?.line, 42)
        XCTAssertEqual(r.checks.first?.answer, "concern")
        XCTAssertEqual(r.resolved.first?.commentQuote, "name the retention period")
        XCTAssertEqual(r.chapters.map(\.key), ["ch:0", "ch:1"])
        XCTAssertEqual(r.chapters[1].end, 200)
        XCTAssertTrue(r.codeRead)
        XCTAssertEqual(r.dropped, 2)
        XCTAssertEqual(r.findings.count, 5)
        // A missing agreement: no anchor, the chapter the reviewer named.
        XCTAssertEqual(r.agreements.last?.status, "missing")
        XCTAssertNil(r.agreements.last?.anchor)
        XCTAssertEqual(r.agreements.last?.chapter, "ch:1")
    }

    /// F2: Go's empty result (no idea key; testdata/result_empty.golden)
    /// and an older stored one with an empty idea both read as no idea.
    func testEmptyIdeaReadsAsAbsent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spec_review_result_empty.json")
        let empty = try JSONDecoder().decode(SpecReviewResult.self, from: Data(contentsOf: url))
        XCTAssertEqual(empty.summary, "s")
        XCTAssertNil(empty.idea)
        XCTAssertTrue(empty.agreements.isEmpty)
        let old = #"{"summary":"s","idea":{"owner_quote":"","goal_quote":" ","verdict":"","note":"","#
            + #""owner_source":{"kind":"","ref":"","quote":"","speaker":""}}}"#
        XCTAssertNil(try JSONDecoder().decode(SpecReviewResult.self, from: Data(old.utf8)).idea)
    }

    func testDecodingToleratesUnknownKeysAndEnums() throws {
        let json = #"{"summary":"s","future":{"x":1},"agreements":[{"key":"ag:1","text":"t","status":"brand_new","where":null,"extra":true}]}"#
        let r = try JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.agreements.first?.status, "brand_new")
        XCTAssertNil(r.agreements.first?.anchor)
        XCTAssertTrue(r.chapters.isEmpty)
        XCTAssertNil(r.idea)

        let queue = try TestDatabase.create()
        func row(_ status: String, _ result: String) throws -> SpecReviewRow {
            try queue.read { db in
                let raw = try XCTUnwrap(Row.fetchOne(
                    db,
                    sql: "SELECT 7 AS ask_id, ? AS status, '' AS reason, ? AS result, 'p' AS provider, 'm' AS model, 0 AS dropped, 0 AS attempt",
                    arguments: [status, result]
                ))
                return try SpecReviewRow(row: raw)
            }
        }
        // A status this build does not know decodes as unknown.
        XCTAssertEqual(try row("novel", "").status, .unknown)
        let badRow = try row("done", "{nope")
        XCTAssertNil(badRow.result)
        XCTAssertTrue(badRow.resultUnreadable)
    }

    func testAnswerSendsOnlyCommentMarks() throws {
        let r = try golden()
        let marks = [
            "ag:0123456789ab": SpecReviewMark(key: "ag:0123456789ab", state: .ok),
            "da:0123456789ab": SpecReviewMark(key: "da:0123456789ab", state: .comment, body: "ask first")
        ]
        let a = SpecReviewAnswer.build(result: r, marks: marks, base: OwnerAskAnswer(note: "n"), verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.count, 1)
        XCTAssertEqual(a.comments[0].body, "State is kept in the local database — ask first")
        XCTAssertEqual(a.comments[0].heading, "Decisions")
        XCTAssertEqual(a.comments[0].quote, "Mute state lives in the local database")
        XCTAssertEqual(a.verdict, .changes)
        XCTAssertEqual(a.note, "n")
    }

    /// **Fix** is a comment with no body: the finding's text goes as it is,
    /// and as an orphan after a re-run, its kept text.
    func testFixSendsTheFindingAsItIs() throws {
        let r = try golden()
        let marks = [
            "da:0123456789ab": SpecReviewMark(key: "da:0123456789ab", state: .comment, about: "State is kept in the local database"),
            "ag:gone": SpecReviewMark(key: "ag:gone", state: .comment, about: "Threads stay muted")
        ]
        let a = SpecReviewAnswer.build(result: r, marks: marks, verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.map(\.body), [
            "State is kept in the local database",
            "From the previous run: Threads stay muted"
        ])
    }

    func testAnswerSkipsNotUseful() throws {
        let r = try golden()
        let marks = [
            "ag:0123456789ab": SpecReviewMark(key: "ag:0123456789ab", state: .notUseful),
            "da:0123456789ab": SpecReviewMark(key: "da:0123456789ab", state: .comment, body: "ask first")
        ]
        let a = SpecReviewAnswer.build(result: r, marks: marks, base: OwnerAskAnswer(note: "n"), verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.count, 1)
        XCTAssertEqual(a.comments[0].body, "State is kept in the local database — ask first")
        XCTAssertTrue(SpecReviewAnswer.orphanMarks(result: r, marks: ["gone": SpecReviewMark(key: "gone", state: .notUseful)]).isEmpty)
    }

    func testQueriesReadNotUseful() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'wb', '/tmp/wb')")
            try db.execute(sql: "INSERT INTO owner_asks (id, project_id, kind, title, doc_path) VALUES (1, 1, 'review', 't', 'spec.md')")
            try SpecReviewQueries.setMark(db, askID: 1, mark: .init(key: "ag:1", state: .notUseful), now: Date(timeIntervalSince1970: 1_790_000_000))
        }
        let marks = try db.read { try SpecReviewQueries.marks($0, askID: 1) }
        XCTAssertEqual(marks["ag:1"], SpecReviewMark(key: "ag:1", state: .notUseful))
    }

    func testAnswerAnchorsUnanchoredToChapter() throws {
        var r = chapterized(try golden())
        r.checks = []
        let json = #"{"blind_spots":[{"key":"bs:1","text":"No word on threads","chapter":"ch:1"}]}"#
        r.blindSpots = try JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8)).blindSpots
        let marks = ["bs:1": SpecReviewMark(key: "bs:1", state: .comment, body: "add")]
        let a = SpecReviewAnswer.build(result: r, marks: marks, verdict: .changes, snapshot: snapshot)
        let comment = try XCTUnwrap(a.comments.first)
        XCTAssertEqual(comment.heading, "Behaviour")
        XCTAssertEqual(comment.quote, "Muting lasts twenty-four hours")
        XCTAssertTrue(snapshot.contains(comment.quote))
    }

    func testOrphanMarksListed() throws {
        let r = try golden()
        let marks = [
            "ag:0123456789ab": SpecReviewMark(key: "ag:0123456789ab", state: .comment, body: "keep"),
            "ag:gone": SpecReviewMark(key: "ag:gone", state: .comment, body: "old note"),
            "ag:okgone": SpecReviewMark(key: "ag:okgone", state: .ok)
        ]
        let orphans = SpecReviewAnswer.orphanMarks(result: r, marks: marks)
        XCTAssertEqual(orphans.map(\.key), ["ag:gone"])
        let a = SpecReviewAnswer.build(result: r, marks: marks, verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.count, 2)
        let sent = try XCTUnwrap(a.comments.last)
        XCTAssertEqual(sent.body, "From the previous run: old note")
        XCTAssertEqual(sent.heading, "Title")
        XCTAssertEqual(sent.quote, "Intro text")
    }

    func testMarksRoundTrip() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO projects (id, name, folder_path) VALUES (1, 'wb', '/tmp/wb')
                """)
            try db.execute(sql: """
                INSERT INTO owner_asks (id, project_id, kind, title, doc_path) VALUES (1, 1, 'review', 't', 'spec.md')
                """)
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try db.write { db in
            try SpecReviewQueries.setMark(db, askID: 1, mark: .init(key: "ag:1", state: .comment, body: "a"), now: now)
            try SpecReviewQueries.setMark(db, askID: 1, mark: .init(key: "ch:1", state: .viewed), now: now)
            try SpecReviewQueries.setMark(db, askID: 1, mark: .init(key: "ag:1", state: .ok), now: now)
            try SpecReviewQueries.setMark(
                db, askID: 1, mark: .init(key: "ag:2", state: .comment, body: "old note", about: "Threads stay muted"), now: now
            )
        }
        var marks = try db.read { try SpecReviewQueries.marks($0, askID: 1) }
        XCTAssertEqual(marks["ag:1"], SpecReviewMark(key: "ag:1", state: .ok))
        XCTAssertEqual(marks["ag:2"], SpecReviewMark(key: "ag:2", state: .comment, body: "old note", about: "Threads stay muted"))
        try db.write { try SpecReviewQueries.clearMark($0, askID: 1, key: "ag:2") }
        XCTAssertEqual(marks["ch:1"]?.state, .viewed)
        try db.write { try SpecReviewQueries.clearMark($0, askID: 1, key: "ag:1") }
        marks = try db.read { try SpecReviewQueries.marks($0, askID: 1) }
        XCTAssertEqual(Array(marks.keys), ["ch:1"])
        XCTAssertNil(try db.read { try SpecReviewQueries.row($0, askID: 1) })
    }

    func testUnanchoredQuoteIsRenderedBodyLineWithMultibyteText() throws {
        let doc = "# Заголовок\nВступ\n## Поведение ✓\n\n- **Тихий** режим на сутки\n"
        let start = doc.utf8.count - "## Поведение ✓\n\n- **Тихий** режим на сутки\n".utf8.count
        let json = """
        {"chapters":[{"key":"ch:1","heading":"Поведение ✓","start":\(start),"end":\(doc.utf8.count)},
        {"key":"ch:2","heading":"## Пусто","start":\(doc.utf8.count),"end":\(doc.utf8.count)}],
        "blind_spots":[{"key":"bs:1","text":"t","chapter":"ch:1"},{"key":"bs:2","text":"u","chapter":"ch:2"}]}
        """
        let r = try JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8))
        let marks = [
            "bs:1": SpecReviewMark(key: "bs:1", state: .comment, body: "a"),
            "bs:2": SpecReviewMark(key: "bs:2", state: .comment, body: "b")
        ]
        let a = SpecReviewAnswer.build(result: r, marks: marks, verdict: .changes, snapshot: doc)
        XCTAssertEqual(a.comments[0].heading, "Поведение ✓")
        XCTAssertEqual(a.comments[0].quote, "Тихий режим на сутки")
        // A chapter with no body line quotes its title.
        XCTAssertEqual(a.comments[1].heading, "Пусто")
        XCTAssertEqual(a.comments[1].quote, "Пусто")
    }
    /// The margin comments and question answers of the draft go with the
    /// marks' comments; the verdict is the button's.
    func testAnswerMergesTheDraft() throws {
        let r = try golden()
        let margin = OwnerAskAnswer.Comment(
            anchor: CommentAnchor(quote: "Intro text", prefix: "Title\n", suffix: "", heading: "Title"), body: "too vague"
        )
        let base = OwnerAskAnswer(
            verdict: .approved, answers: [.init(id: "q1", labels: ["Yes"])], comments: [margin], note: "n"
        )
        let marks = ["da:0123456789ab": SpecReviewMark(key: "da:0123456789ab", state: .comment, body: "ask first")]
        let a = SpecReviewAnswer.build(result: r, marks: marks, base: base, verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.verdict, .changes)
        XCTAssertEqual(a.answers.map(\.id), ["q1"])
        XCTAssertEqual(a.comments.map(\.body), ["too vague", "State is kept in the local database — ask first"])
        XCTAssertEqual(a.note, "n")
    }

    /// A finding's raw-markdown quote is anchored on the rendered snapshot,
    /// with rendered context, so the closed ask finds it again.
    func testAnchorOnMarkdownQuoteRelocatesInTheRenderedDocument() throws {
        let doc = "# Title\nIntro\n## Behaviour\nThe `mute_until` column keeps **one day** of quiet.\n"
        let json = """
        {"agreements":[{"key":"ag:1","text":"A day","status":"as_agreed","chapter":"ch:1",
        "where":{"heading":"Behaviour","quote":"The `mute_until` column keeps **one day**"}}]}
        """
        let r = try JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8))
        let marks = ["ag:1": SpecReviewMark(key: "ag:1", state: .comment, body: "ok")]
        let comment = try XCTUnwrap(
            SpecReviewAnswer.build(result: r, marks: marks, verdict: .changes, snapshot: doc).comments.first
        )
        XCTAssertEqual(comment.quote, "The mute_until column keeps one day")
        XCTAssertEqual(comment.heading, "Behaviour")
        XCTAssertTrue(comment.suffix.hasPrefix(" of quiet."), comment.suffix)
        XCTAssertTrue(comment.prefix.contains("Behaviour") && !comment.prefix.contains("#"), "rendered context: \(comment.prefix)")
        let rendered = DocumentRendering.render(doc)
        let anchor = OwnerAskReviewText.anchor(of: comment)
        let range = try XCTUnwrap(OwnerAskReviewText.range(of: anchor, in: rendered))
        XCTAssertEqual((rendered.text as NSString).substring(with: range), "The mute_until column keeps one day")
    }

    /// A comment whose finding a re-run dropped keeps the finding's text.
    func testOrphanCommentKeepsItsFindingText() throws {
        let r = try golden()
        let marks = ["ag:gone": SpecReviewMark(key: "ag:gone", state: .comment, body: "old note", about: "Threads stay muted")]
        let a = SpecReviewAnswer.build(result: r, marks: marks, verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.last?.body, "From the previous run: Threads stay muted — old note")
    }

    func testDecisionsListFromTheSnapshot() {
        let doc = """
        # T
        ## Decisions
        - Mute lives in the local DB (ask #3)
        - The sidebar refreshes
          once a minute (conversation)
        1. Numbered one
        ```
        - not an item
        ```
        ### Detail
        - nested heading keeps the section
        ## Next
        - not a decision
        """
        XCTAssertEqual(SpecReviewDecisions.items(in: doc), [
            "Mute lives in the local DB (ask #3)",
            "The sidebar refreshes once a minute (conversation)",
            "Numbered one",
            "nested heading keeps the section"
        ])
        XCTAssertNil(SpecReviewDecisions.items(in: "# T\n## Goal\nx\n"))
        XCTAssertEqual(SpecReviewDecisions.items(in: "## Decisions\n"), [])
    }

    /// F4, the Go rule: a `## ` heading whose title starts with the word
    /// "Decisions", any case; no other level, no longer word.
    func testDecisionsHeadingMayGoOnButIsLevelTwoOnly() {
        XCTAssertEqual(SpecReviewDecisions.items(in: "# T\n## Decisions (owner's)\n- Local state (ask #1)\n## Next\n"), [
            "Local state (ask #1)"
        ])
        XCTAssertEqual(SpecReviewDecisions.items(in: "## DECISIONS — approved\n- a\n"), ["a"])
        XCTAssertNil(SpecReviewDecisions.items(in: "# Decisions\n- a\n"))
        XCTAssertNil(SpecReviewDecisions.items(in: "### Decisions\n- a\n"))
        XCTAssertNil(SpecReviewDecisions.items(in: "## Decisionsless\n- a\n"))
        XCTAssertNil(SpecReviewDecisions.items(in: "## Open decisions\n- a\n"))
    }

    // MARK: - Author loop answer (spec 2026-10-26 §7)

    private func loopLedger() throws -> [SpecReviewLedgerEntry] {
        try JSONDecoder().decode([SpecReviewLedgerEntry].self, from: Data("""
        [{"key":"ag:1","text":"Mute lasts a day","round":1,"reply":{"reply":"fixed","note":""},"verdict":"resolved","settled":2},
         {"key":"bs:2","text":"No undo","where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours"},
          "reply":{"reply":"disagree","note":"out of scope"},"verdict":"disputed","verdict_note":"still needed","settled":2},
         {"key":"ck:3","text":"q","verdict":"unsettled","verdict_note":"","settled":3}]
        """.utf8))
    }

    func testLoopAnswerKeepsTheOwnersVerdict() throws {
        let marks = ["bs:2": SpecReviewMark(key: "bs:2", state: .comment, body: "do it"),
                     "ck:3": SpecReviewMark(key: "ck:3", state: .comment),
                     "ag:1": SpecReviewMark(key: "ag:1", state: .comment, body: "wrong")]
        // The loop screen's Approve.
        let a = SpecReviewAnswer.build(result: nil, marks: marks, loop: try loopLedger(), verdict: .approved, snapshot: snapshot)
        XCTAssertEqual(a.verdict, .approved)
        // The classic footer's or the phone's Request changes on an owner-loop row.
        var changes = OwnerAskAnswer()
        changes.verdict = .changes
        XCTAssertEqual(SpecReviewAnswer.build(result: nil, marks: marks, loop: try loopLedger(), base: changes, snapshot: snapshot).verdict,
                       .changes, "a loop never turns the owner's Request changes into approved")
        XCTAssertEqual(SpecReviewAnswer.build(result: nil, marks: [:], loop: [], base: changes, snapshot: snapshot).verdict,
                       .changes, "an empty ledger (round 1's reviewer failed) keeps the owner's verdict too")
        XCTAssertEqual(a.comments.map(\.body), [
            "Reopened: Mute lasts a day\n\nwrong",
            "Reviewer is right: No undo — still needed\n\ndo it",
            "Reviewer is right: q"
        ])
        XCTAssertEqual(a.comments[1].heading, "Behaviour")
        XCTAssertEqual(a.comments[1].quote, "Muting lasts twenty-four hours")
        XCTAssertEqual(a.comments[2].heading, "Title", "no where, no chapter: the first heading")
    }

    func testLoopBodyDropsTheAuthorsReasonCopiedAsTheVerdictNote() throws {
        let entries = try JSONDecoder().decode([SpecReviewLedgerEntry].self, from: Data("""
        [{"key":"a","text":"t","note":"","reply":{"reply":"disagree","note":"no"},"verdict":"unsettled","verdict_note":"no"},
         {"key":"b","text":"t","note":"own","reply":{"reply":"disagree","note":"no"},"verdict":"unsettled","verdict_note":"no"},
         {"key":"c","text":"t","note":"own","reply":{"reply":"disagree","note":"no"},"verdict":"disputed","verdict_note":"still"}]
        """.utf8))
        XCTAssertEqual(SpecReviewAnswer.loopBody(entries[0], owner: ""), "Reviewer is right: t")
        XCTAssertEqual(SpecReviewAnswer.loopBody(entries[1], owner: ""), "Reviewer is right: t — own")
        XCTAssertEqual(SpecReviewAnswer.loopBody(entries[2], owner: "x"), "Reviewer is right: t — still\n\nx")
    }

    func testLoopUnpickedAndAuthorRightSendNothing() throws {
        let marks = ["bs:2": SpecReviewMark(key: "bs:2", state: .ok)]
        let a = SpecReviewAnswer.build(result: nil, marks: marks, loop: try loopLedger(), verdict: .approved, snapshot: snapshot)
        XCTAssertEqual(a.verdict, .approved)
        XCTAssertTrue(a.comments.isEmpty)
    }
}
