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
        XCTAssertEqual(r.findings.count, 4)
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
        let a = SpecReviewAnswer.build(result: r, marks: marks, note: "n", verdict: .changes, snapshot: snapshot)
        XCTAssertEqual(a.comments.count, 1)
        XCTAssertEqual(a.comments[0].body, "State is kept in the local database — ask first")
        XCTAssertEqual(a.comments[0].heading, "Decisions")
        XCTAssertEqual(a.comments[0].quote, "Mute state lives in the local database")
        XCTAssertEqual(a.verdict, .changes)
        XCTAssertEqual(a.note, "n")
    }

    func testAnswerAnchorsUnanchoredToChapter() throws {
        var r = chapterized(try golden())
        r.checks = []
        let json = #"{"blind_spots":[{"key":"bs:1","text":"No word on threads","chapter":"ch:1"}]}"#
        r.blindSpots = try JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8)).blindSpots
        let marks = ["bs:1": SpecReviewMark(key: "bs:1", state: .comment, body: "add")]
        let a = SpecReviewAnswer.build(result: r, marks: marks, note: "", verdict: .changes, snapshot: snapshot)
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
        let a = SpecReviewAnswer.build(result: r, marks: marks, note: "", verdict: .changes, snapshot: snapshot)
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
        }
        var marks = try db.read { try SpecReviewQueries.marks($0, askID: 1) }
        XCTAssertEqual(marks["ag:1"], SpecReviewMark(key: "ag:1", state: .ok))
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
        let a = SpecReviewAnswer.build(result: r, marks: marks, note: "", verdict: .changes, snapshot: doc)
        XCTAssertEqual(a.comments[0].heading, "Поведение ✓")
        XCTAssertEqual(a.comments[0].quote, "Тихий режим на сутки")
        // A chapter with no body line quotes its title.
        XCTAssertEqual(a.comments[1].heading, "Пусто")
        XCTAssertEqual(a.comments[1].quote, "Пусто")
    }
}
