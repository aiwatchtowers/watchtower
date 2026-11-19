import XCTest
@testable import WatchtowerChatText

/// `internal/chat/testdata/artifact_parse_cases.json` is read by the Go twin
/// (`chatstore.ParseArtifacts`) too: one fixture, pinned from both sides.
/// Only complete blocks count, and the last block of a key replaces the earlier
/// one in place.
final class ArtifactParseFixtureTests: XCTestCase {
    private struct Case: Decodable {
        struct Expected: Decodable, Equatable {
            let key: String
            let kind: String
            let title: String
            let content: String
            let meta: [String: String]
        }
        let name: String
        let text: String
        let final: Bool
        let expect: [Expected]
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WatchtowerChatTextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerChatText
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/testdata/artifact_parse_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testSharedArtifactParseCases() throws {
        let cases = try Self.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for tc in cases {
            var kept: [Case.Expected] = []
            for draft in ArtifactParser.parse(tc.text, final: tc.final).artifacts where draft.isComplete {
                let item = Case.Expected(key: draft.key, kind: draft.kind, title: draft.title,
                                         content: draft.content, meta: draft.meta)
                if let at = kept.firstIndex(where: { $0.key == item.key }) {
                    kept[at] = item
                } else {
                    kept.append(item)
                }
            }
            XCTAssertEqual(kept, tc.expect, tc.name)
        }
    }
}
