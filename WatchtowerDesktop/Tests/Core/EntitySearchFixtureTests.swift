import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// `internal/chatengine/testdata/entity_search_cases.json` pins Go's
/// `Engine.EntitySearch` to the Swift pickers: `MentionSearch.search` for a
/// case with no kinds (the `@` picker), else `ChatEntitySearch.search` of
/// each kind in order with the project source picker's limit (dual path,
/// pinned from both sides).
final class EntitySearchFixtureTests: XCTestCase {
    private struct Hit: Decodable, Equatable {
        let kind: String
        let id: String
        let label: String
        let detail: String
    }

    private struct Case: Decodable {
        let name: String
        let query: String
        let kinds: [String]
        let hits: [Hit]
    }

    private struct Fixture: Decodable {
        let seed: [String]
        let cases: [Case]
    }

    private static let pickerLimit = 30

    private static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chatengine/testdata/entity_search_cases.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testEntitySearchFixtureMatchesGo() throws {
        let fixture = try Self.fixture()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10)
        let db = try TestDatabase.create()
        try db.write { d in
            for statement in fixture.seed { try d.execute(sql: statement) }
        }
        for c in fixture.cases {
            let got: [Hit] = try db.read { d in
                if c.kinds.isEmpty {
                    return try MentionSearch.search(d, query: c.query).map {
                        Hit(kind: $0.kind.rawValue, id: $0.ref, label: $0.label, detail: $0.detail)
                    }
                }
                return try c.kinds.flatMap { raw in
                    let kind = try XCTUnwrap(ChatEntityKind(rawValue: raw), raw)
                    return try ChatEntitySearch.search(d, kind: kind, query: c.query, limit: Self.pickerLimit).map {
                        Hit(kind: $0.kind.rawValue, id: $0.ref, label: $0.label, detail: $0.detail)
                    }
                }
            }
            XCTAssertEqual(got, c.hits, c.name)
        }
    }
}
