import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class OwnerAskQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private static let reviewPayload = #"""
        {"focus":[{"text":"Rollout order?","heading":"Rollout"},{"text":"Overall"}],
         "questions":[{"id":"1","question":"Flag?","options":[{"label":"Yes","recommended":true},{"label":"No"}]}],
         "checklist":[]}
        """#

    private func session(_ d: Database, projectID: Int64) throws -> Int64 {
        try TerminalSessionQueries.create(d, .init(projectID: projectID, kind: .shell, title: "s", folderPath: "/tmp/acme")).id
    }

    /// A `created_at` `minutes` before now, in the column's UTC form.
    private func stamp(minutesAgo minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
    }

    func testARowDecodesItsPayloadAndAnswer() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p, kind: "review", title: "Spec",
                                                     payload: Self.reviewPayload, docPath: "docs/spec.md")
            try d.execute(sql: """
                INSERT INTO owner_asks (project_id, kind, title, payload)
                VALUES (?, 'check', 'Try it', '{"focus":[],"questions":[],"checklist":[{"text":"Launch"},{"id":"q","text":"Quit","hint":"Cmd-Q"}]}')
                """, arguments: [p])
            let asks = try OwnerAskQueries.openAsks(d, projectID: p).asks
            XCTAssertEqual(asks.map(\.kind), [.review, .check])
            let review = asks[0]
            XCTAssertEqual(review.id, id)
            XCTAssertEqual(review.docPath, "docs/spec.md")
            XCTAssertEqual(review.payload.focus, [OwnerAskFocus(text: "Rollout order?", heading: "Rollout"), OwnerAskFocus(text: "Overall")])
            XCTAssertEqual(review.payload.questions.map(\.id), ["1"])
            XCTAssertEqual(review.payload.questions.first?.options.first?.recommended, true)
            XCTAssertNil(review.answer)
            XCTAssertEqual(
                asks[1].payload.checklist,
                [OwnerAskCheckItem(id: "1", text: "Launch"), OwnerAskCheckItem(id: "q", text: "Quit", hint: "Cmd-Q")],
                "a missing id is the 1-based position, as Go stores it"
            )
        }
    }

    /// A payload this app cannot read is never shown as an ask without
    /// questions: the row is left out and named, and the good rows around it
    /// still list — open and closed alike.
    func testABrokenPayloadIsLeftOutAndNamedTheOthersStillList() throws {
        let broken = #"{"questions":[{"question":"Only one option","options":[{"label":"A"}]}]}"#
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let first = try TestDatabase.insertOwnerAsk(d, projectID: p, createdAt: stamp(minutesAgo: 3))
            let bad = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: broken, createdAt: stamp(minutesAgo: 2))
            let last = try TestDatabase.insertOwnerAsk(d, projectID: p, createdAt: stamp(minutesAgo: 1))
            let open = try OwnerAskQueries.openAsks(d, projectID: p)
            XCTAssertEqual(open.asks.map(\.id), [first, last])
            XCTAssertEqual(open.unreadableIDs, [bad])
            XCTAssertEqual(open.problem, "1 ask could not be read (#\(bad)).")

            let badClosed = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: broken, status: "withdrawn", withdrawnReason: "agent")
            let badAnswer = try TestDatabase.insertOwnerAsk(d, projectID: p, status: "answered", answer: "not json")
            let goodClosed = try TestDatabase.insertOwnerAsk(d, projectID: p, status: "withdrawn", withdrawnReason: "agent",
                                                             createdAt: stamp(minutesAgo: 10))
            let closed = try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: nil)
            XCTAssertEqual(closed.asks.map(\.id), [goodClosed])
            XCTAssertEqual(Set(closed.unreadableIDs), [badClosed, badAnswer])
            XCTAssertTrue(closed.problem?.hasPrefix("2 asks could not be read (#") == true, closed.problem ?? "nil")
            XCTAssertThrowsError(try OwnerAskQueries.ask(d, id: bad, projectID: p), "a single read still refuses the row")
        }
    }

    func testOpenAsksAreThisWorkbenchsOpenOnesOldestFirst() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let other = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            let newer = try TestDatabase.insertOwnerAsk(d, projectID: p, title: "newer", createdAt: stamp(minutesAgo: 1))
            let older = try TestDatabase.insertOwnerAsk(d, projectID: p, title: "older", createdAt: stamp(minutesAgo: 2))
            try TestDatabase.insertOwnerAsk(d, projectID: p, status: "withdrawn")
            try TestDatabase.insertOwnerAsk(d, projectID: other)
            XCTAssertEqual(try OwnerAskQueries.openAsks(d, projectID: p).asks.map(\.id), [older, newer])
        }
    }

    func testClosedAsksAreOneSessionsNewestFirstOrTheSessionlessOnes() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s = try session(d, projectID: p)
            let answer = #"{"answers":[{"id":"1","labels":["A"],"other":""}],"checklist":[],"comments":[],"note":"","verdict":""}"#
            let answered = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s, status: "answered", answer: answer,
                                                           createdAt: stamp(minutesAgo: 2))
            let withdrawn = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s, status: "withdrawn",
                                                            createdAt: stamp(minutesAgo: 1))
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s)
            let outside = try TestDatabase.insertOwnerAsk(d, projectID: p, status: "delivered", answer: answer)

            let closed = try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: s).asks
            XCTAssertEqual(closed.map(\.id), [withdrawn, answered])
            XCTAssertEqual(closed[1].answer?.answers, [.init(id: "1", labels: ["A"])])
            XCTAssertEqual(try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: nil).asks.map(\.id), [outside])
        }
    }

    func testAnswerWritesTheAnswerAndTheUTCTimeOnce() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p, kind: "review", payload: Self.reviewPayload, docPath: "docs/spec.md")
            let answer = OwnerAskAnswer(verdict: .approved, answers: [.init(id: "1", labels: ["Yes"])])
            let now = Date()
            try OwnerAskQueries.answer(d, askID: id, projectID: p, with: answer, at: now)

            let row = try XCTUnwrap(Row.fetchOne(d, sql: "SELECT status, answer, answered_at FROM owner_asks WHERE id = ?", arguments: [id]))
            XCTAssertEqual(row["status"] as String, "answered")
            XCTAssertEqual(row["answer"] as String, try answer.encoded())
            let stamp: String = row["answered_at"]
            XCTAssertTrue(stamp.hasSuffix("Z"), stamp)
            let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: stamp))
            XCTAssertEqual(parsed.timeIntervalSince1970, now.timeIntervalSince1970.rounded(.down), accuracy: 1)

            XCTAssertThrowsError(try OwnerAskQueries.answer(d, askID: id, projectID: p, with: OwnerAskAnswer(verdict: .changes))) {
                XCTAssertEqual($0 as? AskAnswerError, .notOpen, "a second answer is refused")
            }
            XCTAssertEqual(try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: nil).asks.first?.answer, answer)
        }
    }

    /// The agent withdrew (or superseded) the ask while the owner was
    /// answering: the guarded write changes nothing and says so.
    func testAnsweringAnAskWithdrawnMeanwhileThrowsNotOpenAndWritesNothing() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let other = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p)
            try d.execute(sql: "UPDATE owner_asks SET status = 'withdrawn', withdrawn_reason = 'agent' WHERE id = ?", arguments: [id])
            let answer = OwnerAskAnswer(answers: [.init(id: "1", labels: ["A"])])

            XCTAssertThrowsError(try OwnerAskQueries.answer(d, askID: id, projectID: p, with: answer)) {
                XCTAssertEqual($0 as? AskAnswerError, .notOpen)
            }
            let row = try XCTUnwrap(Row.fetchOne(d, sql: "SELECT status, answer, answered_at FROM owner_asks WHERE id = ?", arguments: [id]))
            XCTAssertEqual(row["status"] as String, "withdrawn")
            XCTAssertEqual(row["answer"] as String, "")
            XCTAssertEqual(row["answered_at"] as String, "")

            let open = try TestDatabase.insertOwnerAsk(d, projectID: p)
            XCTAssertThrowsError(try OwnerAskQueries.answer(d, askID: open, projectID: other, with: answer)) {
                XCTAssertEqual($0 as? AskAnswerError, .notOpen, "another workbench's ask is never answered")
            }
            XCTAssertEqual(try OwnerAskQueries.openAsks(d, projectID: p).asks.map(\.id), [open])
        }
    }

    /// The board's detail card (spec 2026-10-03 Part 8): a target's asks of
    /// every status, newest first; another target's or workbench's never.
    func testTargetAsksListOneTargetsAsksNewestFirstWithTheirStatus() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let otherTarget = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let old = try TestDatabase.insertOwnerAsk(d, projectID: p, targetID: t, title: "Old", status: "withdrawn",
                                                      withdrawnReason: "superseded", createdAt: stamp(minutesAgo: 3))
            let answered = try TestDatabase.insertOwnerAsk(d, projectID: p, targetID: t, title: "Answered", status: "answered",
                                                           answer: "{}", createdAt: stamp(minutesAgo: 2))
            // Listed even when its payload would not decode as an `OwnerAsk`.
            let open = try TestDatabase.insertOwnerAsk(d, projectID: p, targetID: t, title: "Open", payload: "not json",
                                                       createdAt: stamp(minutesAgo: 1))
            try TestDatabase.insertOwnerAsk(d, projectID: p, targetID: otherTarget)
            try TestDatabase.insertOwnerAsk(d, projectID: p)

            let asks = try OwnerAskQueries.targetAsks(d, projectID: p, targetID: t)
            XCTAssertEqual(asks.map(\.id), [open, answered, old])
            XCTAssertEqual(asks.map(\.statusLabel), ["Open", "Answered", "Superseded"])
            XCTAssertEqual(asks.first?.title, "Open")
            let foreign = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            XCTAssertTrue(try OwnerAskQueries.targetAsks(d, projectID: foreign, targetID: t).isEmpty)
        }
    }

    func testListItemStatusLabels() {
        let item = { (status: String, reason: String) in
            OwnerAskListItem(row: ["id": 1, "title": "t", "status": status, "withdrawn_reason": reason]).statusLabel
        }
        XCTAssertEqual(item("delivered", ""), "Delivered")
        XCTAssertEqual(item("withdrawn", "agent"), "Withdrawn")
        XCTAssertEqual(item("withdrawn", "superseded"), "Superseded")
        XCTAssertEqual(item("later", ""), "later", "a status this build does not know is shown as stored")
    }

    func testOneAskByIDOfItsWorkbenchOnly() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p, status: "withdrawn", withdrawnReason: "agent")
            XCTAssertEqual(try OwnerAskQueries.ask(d, id: id, projectID: p)?.status, .withdrawn, "closed asks are read too")
            let foreign = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            XCTAssertNil(try OwnerAskQueries.ask(d, id: id, projectID: foreign))
            XCTAssertNil(try OwnerAskQueries.ask(d, id: id + 100, projectID: p))
        }
    }

    func testClosedCountsPerSessionAndOutsideTheApp() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s1 = try session(d, projectID: p)
            let s2 = try session(d, projectID: p)
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s1, status: "answered", answer: "{}")
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s1, status: "withdrawn", withdrawnReason: "agent")
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s1)
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s2, status: "delivered", answer: "{}")
            try TestDatabase.insertOwnerAsk(d, projectID: p, status: "answered", answer: "{}")
            let other = try TestDatabase.insertWorkbench(d, name: "other", folder: "/tmp/other")
            try TestDatabase.insertOwnerAsk(d, projectID: other, status: "answered", answer: "{}")

            let counts = try OwnerAskQueries.closedCounts(d, projectID: p)
            XCTAssertEqual(counts, [s1: 2, s2: 1, nil: 1], "open asks are not counted; nil = outside the app")
        }
    }

    func testReplacementsMapASupersededAskToItsNewRound() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let old = try TestDatabase.insertOwnerAsk(d, projectID: p, status: "withdrawn", withdrawnReason: "superseded")
            let new = try TestDatabase.insertOwnerAsk(d, projectID: p)
            try d.execute(sql: "UPDATE owner_asks SET previous_ask_id = ? WHERE id = ?", arguments: [old, new])
            try TestDatabase.insertOwnerAsk(d, projectID: p)
            XCTAssertEqual(try OwnerAskQueries.replacements(d, projectID: p), [old: new])
        }
    }
}
