import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `owner_ask` projection (mobile POC spec §4.6): the window (open +
/// closed in the last 7 days, ≤ 50 per workbench), the snapshot, payload and
/// text caps, and the Mac-computed `quick` answer.
final class OwnerAskSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private let day: TimeInterval = 86_400
    private let kib = 1024

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func payloads(now: Date = Date()) throws -> [Int64: [String: Any]] {
        let slice = OwnerAskSlice { now }
        let records = try dbPool.read { try slice.records($0) }
        var out: [Int64: [String: Any]] = [:]
        for payload in try SliceJSON.objects(records) {
            out[(payload["id"] as? NSNumber)?.int64Value ?? -1] = payload
        }
        return out
    }

    private func payload(_ id: Int64) throws -> [String: Any] {
        try XCTUnwrap(try payloads()[id], "ask \(id) is not published")
    }

    private func insertAsk(
        kind: String = "question",
        payload: String = #"{"focus": [], "questions": [], "checklist": []}"#,
        status: String = "open",
        answer: String = "",
        createdAt: Date? = nil,
        project: Int64? = nil
    ) throws -> Int64 {
        try dbPool.write { db in
            let project = try project ?? TestDatabase.insertWorkbench(db)
            return try TestDatabase.insertOwnerAsk(
                db, projectID: project, kind: kind, payload: payload, docPath: kind == "review" ? "docs/plan.md" : "",
                status: status, answer: answer, createdAt: createdAt.map(dbStamp)
            )
        }
    }

    private func insertReview(snapshot: String, status: String = "open") throws -> Int64 {
        let id = try insertAsk(kind: "review", status: status, answer: status == "open" ? "" : "{}")
        try dbPool.write { try $0.execute(sql: "UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?", arguments: [snapshot, id]) }
        return id
    }

    /// One question; each option is (label, recommended).
    private func questionPayload(_ options: [(String, Bool)], multi: Bool = false, questions: Int = 1) -> String {
        let optionJSON = options.map { #"{"label": "\#($0.0)", "recommended": \#($0.1)}"# }.joined(separator: ", ")
        let one = (1...questions).map { #"{"id": "q\#($0)", "question": "Which?", "multi": \#(multi), "options": [\#(optionJSON)]}"# }
        return #"{"focus": [], "questions": [\#(one.joined(separator: ", "))], "checklist": []}"#
    }

    // MARK: - Wire shape

    private let optionalKeys: Set<String> = [
        "session_id", "target_id", "withdrawn_reason", "previous_ask_id", "answered_at", "delivered_at",
        "title_clipped", "summary_clipped", "changes_clipped", "payload", "payload_clipped", "doc_path_clipped",
        "doc_snapshot", "doc_clipped", "doc_bytes", "answer", "quick", "spec_review"
    ]
    /// Inside `payload` (passed through verbatim): the Kit mirror decodes a
    /// question's `multi` and an option's `description` as optional.
    private let payloadOptionalKeys: Set<String> = ["multi", "description"]

    func testAnOpenQuestionMatchesTheKitFixture() throws {
        let (ask, target, session) = try dbPool.write { db -> (Int64, Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db, name: "Acme")
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let session = try SliceSeed.insertSession(db, projectID: project)
            let ask = try TestDatabase.insertOwnerAsk(
                db, projectID: project, sessionID: session, targetID: target, title: "Which release?",
                payload: questionPayload([("v0.11", true), ("v0.10", false)])
            )
            try db.execute(sql: "UPDATE owner_asks SET summary = 'Pick one.' WHERE id = ?", arguments: [ask])
            return (ask, target, session)
        }
        let payload = try payload(ask)

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/owner_ask.json"), optionalKeys: optionalKeys,
            nestedOptionalKeys: payloadOptionalKeys
        )
        XCTAssertEqual(payload["workbench_name"] as? String, "Acme")
        XCTAssertEqual((payload["target_id"] as? NSNumber)?.int64Value, target)
        XCTAssertEqual((payload["session_id"] as? NSNumber)?.int64Value, session)
        XCTAssertEqual(payload["status"] as? String, "open")
        XCTAssertNil(payload["withdrawn_reason"], "'' is no reason: the key is omitted")
        XCTAssertNil(payload["answer"], "an open ask carries no answer")
        XCTAssertNil(payload["answered_at"])
        XCTAssertTrue(SliceJSON.allKeys(payload).isDisjoint(with: neverPublishedKeys))
    }

    func testSliceCarriesSpecReviewLine() throws {
        let result = #"{"agreements":[{"key":"a","status":"as_agreed"},{"key":"b","status":"differs"}],"blind_spots":[{"key":"c"}]}"#
        let cases: [(status: String, result: String, reason: String, line: String?)] = [
            ("done", result, "", "1 as agreed · 1 differs · 1 blind spot"),
            ("queued", "", "", "Reviewer is reading…"),
            ("running", "", "", "Reviewer is reading…"),
            ("failed", "", "timed out", "Reviewer failed: timed out"),
            ("skipped", "", "", "Reviewer skipped")
        ]
        let project = try dbPool.write { try TestDatabase.insertWorkbench($0) }
        for item in cases {
            let id = try insertAsk(kind: "review", project: project)
            try dbPool.write { db in
                try db.execute(sql: """
                    INSERT INTO spec_reviews (ask_id, status, result, reason, queued_at)
                    VALUES (?, ?, ?, ?, '2026-10-25T10:00:00Z')
                    """, arguments: [id, item.status, item.result, item.reason])
            }
            let review = try XCTUnwrap(try payload(id)["spec_review"] as? [String: Any], item.status)
            XCTAssertEqual(review["status"] as? String, item.status)
            XCTAssertEqual(review["line"] as? String, item.line)
        }
        let plain = try insertAsk(kind: "review", project: project)
        XCTAssertNil(try payload(plain)["spec_review"], "no reviewer row: today's view")
    }

    /// F9: a done review's counts are decoded once per finish: the same
    /// slice reading the same `finished_at` keeps its line (the result is
    /// not read again); a new finish is read.
    func testDoneReviewLineIsKeptPerFinish() throws {
        let id = try insertAsk(kind: "review")
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at)
                VALUES (?, 'done', '{"blind_spots":[{"key":"c"}]}', '2026-10-25T10:00:00Z', '2026-10-25T10:05:00Z')
                """, arguments: [id])
        }
        let slice = OwnerAskSlice()
        func line() throws -> String? {
            let records = try dbPool.read { try slice.records($0) }
            let payload = try SliceJSON.objects(records).first { ($0["id"] as? NSNumber)?.int64Value == id }
            return (payload?["spec_review"] as? [String: Any])?["line"] as? String
        }
        XCTAssertEqual(try line(), "1 blind spot")
        try dbPool.write { try $0.execute(sql: "UPDATE spec_reviews SET result = '{}' WHERE ask_id = ?", arguments: [id]) }
        XCTAssertEqual(try line(), "1 blind spot", "same finish: the cached line")
        try dbPool.write {
            try $0.execute(sql: "UPDATE spec_reviews SET finished_at = '2026-10-25T10:09:00Z' WHERE ask_id = ?", arguments: [id])
        }
        XCTAssertEqual(try line(), "No findings", "a new finish is decoded")
    }

    func testAnOpenReviewMatchesTheKitFixture() throws {
        let ask = try insertReview(snapshot: "# Plan\n\nStep 1.\n")
        let payload = try payload(ask)

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/owner_ask_review.json"), optionalKeys: optionalKeys,
            nestedOptionalKeys: payloadOptionalKeys
        )
        XCTAssertEqual(payload["doc_snapshot"] as? String, "# Plan\n\nStep 1.\n")
        XCTAssertEqual(payload["doc_path"] as? String, "docs/plan.md")
        XCTAssertNil(payload["doc_clipped"])
        XCTAssertNil(payload["doc_bytes"])
    }

    func testAClosedCheckMatchesTheKitFixture() throws {
        let answer = #"{"verdict":"","answers":[],"checklist":[{"id":"1","state":"ok","note":""}],"comments":[],"note":""}"#
        let ask = try insertAsk(
            kind: "check", payload: #"{"focus": [], "questions": [], "checklist": [{"id": "1", "text": "Launch the app"}]}"#,
            status: "delivered", answer: answer
        )
        let stamp = dbStamp(Date())
        try dbPool.write {
            try $0.execute(sql: "UPDATE owner_asks SET answered_at = ?, delivered_at = ? WHERE id = ?", arguments: [stamp, stamp, ask])
        }
        let payload = try payload(ask)

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/owner_ask_closed.json"), optionalKeys: optionalKeys,
            nestedOptionalKeys: payloadOptionalKeys
        )
        let published = try XCTUnwrap(payload["answer"] as? [String: Any])
        XCTAssertEqual((published["checklist"] as? [[String: Any]])?.first?["state"] as? String, "ok")
        XCTAssertNotNil(payload["answered_at"])
        XCTAssertNotNil(payload["delivered_at"])
    }

    // MARK: - Document snapshot

    func testA2MiBSnapshotIsCutAtTheLastNewlineBefore256KiB() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let full = String(repeating: line, count: 20_971) + String(repeating: "y", count: 52)
        XCTAssertEqual(full.utf8.count, 2 * kib * kib)
        let payload = try payload(try insertReview(snapshot: full))

        let snapshot = try XCTUnwrap(payload["doc_snapshot"] as? String)
        XCTAssertEqual(snapshot.utf8.count, 262_100, "the last whole line under 256 KiB")
        XCTAssertTrue(full.hasPrefix(snapshot))
        XCTAssertTrue(snapshot.hasSuffix("\n"))
        XCTAssertEqual(payload["doc_clipped"] as? Bool, true)
        XCTAssertEqual(payload["doc_bytes"] as? Int, 2 * kib * kib)
    }

    func testASnapshotWithNoNewlineBeforeTheCapIsCutAtAGraphemeBoundary() throws {
        // 18 bytes per family emoji: the cap falls inside a cluster.
        let family = "👩‍👩‍👧"
        let full = String(repeating: family, count: 20_000)
        let payload = try payload(try insertReview(snapshot: full))

        let snapshot = try XCTUnwrap(payload["doc_snapshot"] as? String)
        XCTAssertEqual(snapshot.count, 256 * kib / family.utf8.count)
        XCTAssertEqual(snapshot, String(repeating: family, count: snapshot.count), "no cluster is broken")
        XCTAssertLessThanOrEqual(snapshot.utf8.count, 256 * kib)
        XCTAssertEqual(payload["doc_clipped"] as? Bool, true)
        XCTAssertEqual(payload["doc_bytes"] as? Int, full.utf8.count)
    }

    func testCombiningMarksAtTheCapAreKeptWithTheirLetter() {
        // "e" + combining acute = 3 bytes; 256 KiB is not a multiple of 3.
        let full = String(repeating: "e\u{301}", count: 100_000)
        let clipped = OwnerAskSlice.clipSnapshot(full)

        XCTAssertEqual(clipped.text.unicodeScalars.count % 2, 0, "every letter keeps its mark")
        XCTAssertEqual(clipped.clipped, true)
    }

    /// The shared anchor fixture's clipped case (spec §6.2) is what the
    /// slice's cut leaves at the end of a long snapshot, and the anchor
    /// made on that whole shown text is the fixture's: the phone anchors on
    /// the clipped snapshot as published.
    func testTheAnchorFixturesClippedCaseIsTheEndOfASnapshotTheSliceCut() throws {
        let fixture = try XCTUnwrap(try CommentAnchorFixtures.load().cases.first(where: \.docClipped))
        let filler = "Filler paragraph for the acme snapshot.\n\n"
        let fillerCount = (OwnerAskSlice.maxSnapshotBytes - fixture.markdown.utf8.count) / filler.utf8.count
        let shown = String(repeating: filler, count: fillerCount) + fixture.markdown
        let full = shown + String(repeating: "z", count: OwnerAskSlice.maxSnapshotBytes - shown.utf8.count + 100)

        let clipped = OwnerAskSlice.clipSnapshot(full)

        XCTAssertEqual(clipped.text, shown, "cut right after the fixture's last shown line")
        XCTAssertEqual(clipped.clipped, true)
        let doc = DocumentRendering.render(clipped.text)
        let fillerLength = doc.text.utf16.count - fixture.text.utf16.count
        XCTAssertTrue(doc.text.hasSuffix(fixture.text))
        let selection = NSRange(location: fillerLength + fixture.selection.location, length: fixture.selection.length)
        let anchor = try XCTUnwrap(OwnerAskReviewText.anchor(selection: selection, in: doc))
        XCTAssertEqual(
            CommentAnchorFixtures.Anchor(quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix, heading: anchor.heading),
            fixture.anchor
        )
    }

    func testASnapshotOfExactly256KiBIsNotClipped() throws {
        let full = String(repeating: "a", count: 256 * kib)
        let payload = try payload(try insertReview(snapshot: full))

        XCTAssertEqual(payload["doc_snapshot"] as? String, full)
        XCTAssertNil(payload["doc_clipped"])
        XCTAssertNil(payload["doc_bytes"])
    }

    func testClosedAsksCarryNoSnapshot() throws {
        let payload = try payload(try insertReview(snapshot: "# Plan\n", status: "answered"))

        XCTAssertNil(payload["doc_snapshot"])
        XCTAssertNil(payload["doc_clipped"])
        XCTAssertNil(payload["doc_bytes"])
        XCTAssertEqual(payload["doc_path"] as? String, "docs/plan.md", "the path is still shown")
    }

    // MARK: - Payload and text caps

    func testAPayloadOver64KiBIsDroppedAndFlagged() throws {
        let focus = String(repeating: "f", count: 65 * kib)
        let question = #"{"id": "q", "question": "Which?", "options": [{"label": "A", "recommended": true}, {"label": "B"}]}"#
        let raw = #"{"focus": [{"text": "\#(focus)"}], "questions": [\#(question)], "checklist": []}"#
        let payload = try payload(try insertAsk(payload: raw))

        XCTAssertEqual(payload["payload_clipped"] as? Bool, true)
        XCTAssertNil(payload["payload"])
        XCTAssertNil(payload["quick"], "without the payload the phone only opens the ask on the Mac")
    }

    func testAPayloadUnder64KiBIsPublishedWhole() throws {
        let payload = try payload(try insertAsk(payload: questionPayload([("A", true), ("B", false)])))

        XCTAssertNil(payload["payload_clipped"])
        let published = try XCTUnwrap(payload["payload"] as? [String: Any])
        XCTAssertEqual((published["questions"] as? [Any])?.count, 1)
    }

    func testTextFieldsAreClipped() throws {
        let ask = try insertAsk()
        try dbPool.write {
            try $0.execute(
                sql: "UPDATE owner_asks SET title = ?, summary = ?, changes = ? WHERE id = ?",
                arguments: [String(repeating: "t", count: 201), String(repeating: "s", count: 4001), String(repeating: "c", count: 4001), ask]
            )
        }
        let payload = try payload(ask)

        XCTAssertEqual((payload["title"] as? String)?.count, 200)
        XCTAssertEqual(payload["title_clipped"] as? Bool, true)
        XCTAssertEqual((payload["summary"] as? String)?.count, 4000)
        XCTAssertEqual(payload["summary_clipped"] as? Bool, true)
        XCTAssertEqual((payload["changes"] as? String)?.count, 4000)
        XCTAssertEqual(payload["changes_clipped"] as? Bool, true)
    }

    // MARK: - quick

    func testQuickIsSetForOneSingleSelectQuestionWithARecommendedOptionAnd3Options() throws {
        let payload = try payload(try insertAsk(payload: questionPayload([("A", false), ("B", true), ("C", false)])))

        let quick = try XCTUnwrap(payload["quick"] as? [String: Any])
        XCTAssertEqual(quick["question_id"] as? String, "q1")
        let options = try XCTUnwrap(quick["options"] as? [[String: Any]])
        XCTAssertEqual(options.map { $0["label"] as? String }, ["A", "B", "C"])
        XCTAssertEqual(options.map { $0["recommended"] as? Bool }, [false, true, false])
    }

    func testQuickIsAbsentOtherwise() throws {
        let cases: [(String, String)] = [
            ("multi-select", questionPayload([("A", true), ("B", false), ("C", false)], multi: true)),
            ("no recommended option", questionPayload([("A", false), ("B", false), ("C", false)])),
            ("1 option", questionPayload([("A", true)])),
            ("5 options", questionPayload([("A", true), ("B", false), ("C", false), ("D", false), ("E", false)])),
            ("2 questions", questionPayload([("A", true), ("B", false)], questions: 2))
        ]
        let project = try dbPool.write { try TestDatabase.insertWorkbench($0) }
        for (name, raw) in cases {
            let payload = try payload(try insertAsk(payload: raw, project: project))
            XCTAssertNil(payload["quick"], name)
            XCTAssertNotNil(payload["payload"], "\(name): the ask itself is still published")
        }
    }

    func testQuickIsAbsentOnACheckOrReview() throws {
        let raw = questionPayload([("A", true), ("B", false)])
        XCTAssertNil(try payload(try insertAsk(kind: "check", payload: raw))["quick"])
    }

    // MARK: - Window

    func testClosedAsksAreTheNewest50FromTheLast7Days() throws {
        let now = Date()
        let project = try dbPool.write { try TestDatabase.insertWorkbench($0) }
        var closed: [Int64] = []
        for index in 0..<51 {
            closed.append(try insertAsk(
                status: "answered", answer: "{}", createdAt: now.addingTimeInterval(-Double(index) * 3600), project: project
            ))
        }
        let old = try insertAsk(status: "withdrawn", createdAt: now.addingTimeInterval(-8 * day), project: project)
        let open = try insertAsk(createdAt: now.addingTimeInterval(-30 * day), project: project)
        let published = Set(try payloads(now: now).keys)

        XCTAssertEqual(published.intersection(closed).count, 50)
        XCTAssertFalse(published.contains(closed[50]), "the oldest of the 51 is left out")
        XCTAssertFalse(published.contains(old), "closed 8 days ago")
        XCTAssertTrue(published.contains(open), "every open ask, whatever its age")
    }

    func testTheClosedCapIsPerWorkbench() throws {
        let now = Date()
        let (first, second) = try dbPool.write { db in
            (try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme"),
             try TestDatabase.insertWorkbench(db, name: "acme-2", folder: "/tmp/acme-2"))
        }
        for project in [first, second] {
            for index in 0..<50 {
                _ = try insertAsk(status: "answered", answer: "{}", createdAt: now.addingTimeInterval(-Double(index) * 60), project: project)
            }
        }
        XCTAssertEqual(try payloads(now: now).count, 100)
    }

    func testNoWorkbenchesPublishNoAsks() throws {
        XCTAssertTrue(try payloads().isEmpty)
    }

    func testOwnerAskSliceSkipsAuthorLoop() throws {
        let project = try dbPool.write { try TestDatabase.insertWorkbench($0) }
        let hidden = try insertAsk(kind: "review", project: project)
        let owner = try insertAsk(kind: "review", project: project)
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, queued_at, loop) VALUES
                (?, 'running', '2026-10-26T10:00:00Z', 'author'), (?, 'done', '2026-10-26T10:00:00Z', 'owner')
                """, arguments: [hidden, owner])
        }
        let published = try payloads()
        XCTAssertNil(published[hidden], "a hidden author-loop ask is never published")
        XCTAssertNotNil(published[owner])
    }

    func testPhoneLineForLoopRow() throws {
        let ledger = #"""
            [{"key":"a","kind":"agreement","text":"t","verdict":"resolved"},
             {"key":"b","kind":"blind_spot","text":"t","verdict":"disputed"},
             {"key":"c","kind":"agreement","text":"t","verdict":"unsettled"},
             {"key":"d","kind":"check","text":"t","verdict":"resolved"}]
            """#
        let id = try insertAsk(kind: "review")
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, result, queued_at, finished_at, loop, ledger, loop_end)
                VALUES (?, 'done', '{}', '2026-10-26T10:00:00Z', '2026-10-26T10:05:00Z', 'owner', ?, 'settled')
                """, arguments: [id, ledger])
        }
        let slice = OwnerAskSlice()
        func line() throws -> String? {
            let records = try dbPool.read { try slice.records($0) }
            let payload = try SliceJSON.objects(records).first { ($0["id"] as? NSNumber)?.int64Value == id }
            return (payload?["spec_review"] as? [String: Any])?["line"] as? String
        }
        XCTAssertEqual(try line(), "Reviewer and author disagree on 2 · 2 fixed by the author")
        try dbPool.write {
            try $0.execute(sql: """
                UPDATE spec_reviews SET ledger = '[{"key":"a","kind":"agreement","text":"t","verdict":"resolved"}]',
                loop_end = 'cap' WHERE ask_id = ?
                """, arguments: [id])
        }
        XCTAssertEqual(try line(), "1 fixed by the author", "a changed loop_end is read again with the same finished_at")
    }
}
