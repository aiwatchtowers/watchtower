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
            let asks = try OwnerAskQueries.openAsks(d, projectID: p)
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

    func testABrokenPayloadIsAnErrorNotAnAskWithoutQuestions() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            try TestDatabase.insertOwnerAsk(d, projectID: p, payload: #"{"questions":[{"question":"Only one option","options":[{"label":"A"}]}]}"#)
            XCTAssertThrowsError(try OwnerAskQueries.openAsks(d, projectID: p))
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
            XCTAssertEqual(try OwnerAskQueries.openAsks(d, projectID: p).map(\.id), [older, newer])
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

            let closed = try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: s)
            XCTAssertEqual(closed.map(\.id), [withdrawn, answered])
            XCTAssertEqual(closed[1].answer?.answers, [.init(id: "1", labels: ["A"])])
            XCTAssertEqual(try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: nil).map(\.id), [outside])
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
            XCTAssertEqual(try OwnerAskQueries.closedAsks(d, projectID: p, sessionID: nil).first?.answer, answer)
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
            XCTAssertEqual(try OwnerAskQueries.openAsks(d, projectID: p).map(\.id), [open])
        }
    }
}
