import XCTest
import GRDB
import WatchtowerTestSupport
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
private final class FakeLineDelivery: SpecReviewLineDelivering {
    var answers: [SessionLineDelivery.Delivery] = []
    private(set) var lines: [(line: String, askID: Int64, sessionID: Int64)] = []

    func deliverSpecReviewLine(_ line: String, askID: Int64, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        lines.append((line, askID, sessionID))
        return answers.isEmpty ? .submitted : answers.removeFirst()
    }
}

@MainActor
private final class FakeReveal: SpecReviewRevealing {
    private(set) var asks: [Int64] = []
    private(set) var reasons: [String] = []
    func specReviewReveal(askID: Int64, reason: String) async throws {
        asks.append(askID)
        reasons.append(reason)
    }
}

@MainActor
final class SpecReviewLoopCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var delivery: FakeLineDelivery!
    private var cli: FakeReveal!
    private var center: SpecReviewLoopCenter!
    private var project: Int64 = 0
    private var session: Int64 = 0

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        delivery = FakeLineDelivery()
        cli = FakeReveal()
        center = SpecReviewLoopCenter(dbPool: pool, delivery: delivery, cli: cli)
        (project, session) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "s", folderPath: "/tmp/acme"))
            return (p, s.id)
        }
    }

    override func tearDown() async throws {
        center.stop()
        TestDatabase.cleanup(path: path)
    }

    private func insertRound(round: Int = 1, finishedAt: String = "2026-10-26T10:00:00Z") async throws -> Int64 {
        try await pool.write { [project, session] d in
            let id = try TestDatabase.insertOwnerAsk(d, projectID: project, sessionID: session, kind: "review",
                                                     docPath: "docs/spec.md")
            try d.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, queued_at, finished_at, loop, round, open_items)
                VALUES (?, 'done', '2026-10-26T09:59:00Z', ?, 'author', ?, '[{"key":"ag:1","kind":"agreement","text":"a","note":"","round":1}]')
                """, arguments: [id, finishedAt, round])
            return id
        }
    }

    private func finishNextRound(askID: Int64, round: Int, finishedAt: String) async throws {
        try await pool.write { d in
            try d.execute(sql: "UPDATE spec_reviews SET round = ?, finished_at = ? WHERE ask_id = ?",
                          arguments: [round, finishedAt, askID])
        }
    }

    func testDeliversOncePerFinishedAt() async throws {
        let ask = try await insertRound()
        await center.poll()
        await center.poll()
        XCTAssertEqual(delivery.lines.map(\.line), [OwnerAskPrompt.specReviewLine(askID: ask, round: 1, items: 1)])
        XCTAssertEqual(delivery.lines.first?.sessionID, session)

        try await finishNextRound(askID: ask, round: 2, finishedAt: "2026-10-26T10:05:00Z")
        await center.poll()
        await center.poll()
        XCTAssertEqual(delivery.lines.map(\.line), [
            OwnerAskPrompt.specReviewLine(askID: ask, round: 1, items: 1),
            OwnerAskPrompt.specReviewLine(askID: ask, round: 2, items: 1)
        ])
        XCTAssertEqual(cli.asks, [])
    }

    func testNoSessionRevealsOnce() async throws {
        let ask = try await insertRound()
        delivery.answers = [.noSession, .noSession, .noSession]
        await center.poll()
        await center.poll()
        XCTAssertEqual(cli.asks, [ask])
        XCTAssertEqual(cli.reasons, ["session_gone"])
        XCTAssertEqual(delivery.lines.count, 1, "a revealed ask is not tried again")
    }

    /// Show Now ends the loop with reason owner, and the round's line never
    /// goes to the author after it.
    func testShowNowRevealsForTheOwner() async throws {
        let ask = try await insertRound()
        delivery.answers = [.held]
        await center.poll()
        XCTAssertEqual(center.hidden.map(\.askID), [ask])
        XCTAssertEqual(center.hidden.first?.round, 1)
        let shown = await center.showNow(askID: ask)
        XCTAssertTrue(shown)
        XCTAssertEqual(cli.asks, [ask])
        XCTAssertEqual(cli.reasons, ["owner"])
        XCTAssertEqual(delivery.lines.count, 1, "no line after Show Now")
    }

    func testHeldRetriesNextPoll() async throws {
        _ = try await insertRound()
        delivery.answers = [.held, .queued, .typed]
        await center.poll()
        await center.poll()
        await center.poll()
        await center.poll()
        XCTAssertEqual(delivery.lines.count, 3, "held and queued are tried again; typed counts as delivered")
        XCTAssertEqual(cli.asks, [])
    }

    func testProgressBySession() async throws {
        XCTAssertEqual(center.progress, [:])
        _ = try await insertRound(round: 2)
        await center.poll()
        XCTAssertEqual(center.progress, [session: 2])
        XCTAssertEqual(SpecReviewLoopCenter.progressLine(round: 2), "Spec review: round 2 of 3")
    }
}
