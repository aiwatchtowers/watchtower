import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The hidden-ask predicate, held to the Go fixture `spec_loop_asks.json`
/// (`internal/db/testdata`): an ask is in the loop iff a `spec_reviews` row
/// with `loop = 'author'` names it.
final class OwnerAskQueriesSpecLoopFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Ask: Decodable {
            let id: Int64
            let loop: String?
        }
        let asks: [Ask]
        let visible: [Int64]
    }

    func testNotInSpecLoopMatchesTheGoFixture() throws {
        // Tests/Core/<this file> -> the repository root, four levels up.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("internal/db/testdata/spec_loop_asks.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.asks.isEmpty)

        let db = try TestDatabase.create()
        let visible: [Int64] = try db.write { d in
            let project = try TestDatabase.insertWorkbench(d)
            var ours: [Int64: Int64] = [:]
            for ask in fixture.asks {
                let id = try TestDatabase.insertOwnerAsk(d, projectID: project, kind: "review", docPath: "docs/spec.md")
                ours[ask.id] = id
                guard let loop = ask.loop else { continue }
                try d.execute(sql: """
                    INSERT INTO spec_reviews (ask_id, status, queued_at, loop) VALUES (?, 'running', '2026-10-26T10:00:00Z', ?)
                    """, arguments: [id, loop])
            }
            let ids = try Int64.fetchAll(
                d, sql: "SELECT a.id FROM owner_asks a WHERE \(OwnerAskQueries.notInSpecLoop("a")) ORDER BY a.id"
            )
            let back = Dictionary(uniqueKeysWithValues: ours.map { ($0.value, $0.key) })
            return ids.compactMap { back[$0] }
        }
        XCTAssertEqual(visible.sorted(), fixture.visible.sorted())
    }
}
