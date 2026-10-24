import XCTest
@testable import WatchtowerCore

/// `internal/ideas/testdata/knowledge_prefix_cases.json` is the shared fixture
/// of Go `ParseKnowledgePrefix`; the Swift twin must give the same answer for
/// every case (dual path, pinned from both sides).
final class KnowledgePrefixFixtureTests: XCTestCase {
    private struct Case: Decodable {
        let text: String
        let ok: Bool
        let kind: String
        let body: String
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/ideas/testdata/knowledge_prefix_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testKnowledgePrefixFixtureMatchesGo() throws {
        let all = try Self.cases()
        XCTAssertGreaterThanOrEqual(all.count, 16)
        for c in all {
            let got = KnowledgePrefix.parse(c.text)
            XCTAssertEqual(got != nil, c.ok, "ok for \(c.text.debugDescription)")
            if let got, c.ok {
                XCTAssertEqual(got.kind, c.kind, "kind for \(c.text.debugDescription)")
                XCTAssertEqual(Array(got.body.unicodeScalars), Array(c.body.unicodeScalars),
                               "body for \(c.text.debugDescription)")
            }
        }
    }
}
