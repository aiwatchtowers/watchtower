import Foundation
import XCTest
@testable import WatchtowerChatText

/// `ChatOwnerText.displayParts` over the owner texts Go's composer stores (`internal/chatengine/testdata/
/// compose_cases.json`, the cases Go's `TestCompose_SharedCases` pins), plus the shapes the composer never makes.
final class ChatOwnerTextTests: XCTestCase {
    private struct Mention: Decodable {
        let kind: String
        let id: String
        let label: String
    }

    private struct Quote: Decodable {
        let text: String
    }

    private struct Case: Decodable {
        let name: String
        let text: String
        let skill: String
        let stored: String?
        let mentions: [Mention]
        let quotes: [Quote]
        /// The artifact-comment cases compose a comment batch, not a typed message.
        let artifact: Artifact?
    }

    private struct Artifact: Decodable {
        let key: String
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WatchtowerChatTextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerChatText
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chatengine/testdata/compose_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    /// Every composed owner text reads back as its skill and its words; the skill and REFERENCED lines never
    /// show as text.
    func testEveryComposedTextReadsBackAsTheOwnersWords() throws {
        let cases = try Self.cases().filter { $0.stored != nil && $0.artifact == nil }
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let parts = ChatOwnerText.displayParts(try XCTUnwrap(item.stored))
            XCTAssertEqual(parts.skill, item.skill.isEmpty ? nil : item.skill, item.name)
            if item.quotes.isEmpty {
                XCTAssertEqual(parts.body, item.text.trimmingCharacters(in: .whitespacesAndNewlines), item.name)
            }
            XCTAssertFalse(parts.body.hasPrefix("Use skill ") && !item.skill.isEmpty, item.name)
            for reference in parts.references {
                XCTAssertTrue(item.mentions.contains { "\($0.kind):\($0.id)" == reference.token }, item.name)
            }
        }
    }

    func testReferencesAndSkillAreSplitOff() {
        let stored = """
            Use skill break-down: load it with load_skill first.

            line one

            line two

            REFERENCED: person:1:U1 "Anna \\"Ann\\" I"; jira:PAY-1 "PAY-1"
            """
        let parts = ChatOwnerText.displayParts(stored)
        XCTAssertEqual(parts.skill, "break-down")
        XCTAssertEqual(parts.body, "line one\n\nline two")
        XCTAssertEqual(parts.references, [
            ChatOwnerTextReference(token: "person:1:U1", label: "Anna \"Ann\" I"),
            ChatOwnerTextReference(token: "jira:PAY-1", label: "PAY-1")
        ])
    }

    func testAPlainMessageIsAllBody() {
        let parts = ChatOwnerText.displayParts("just text\n\nmore")
        XCTAssertNil(parts.skill)
        XCTAssertEqual(parts.body, "just text\n\nmore")
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertNil(parts.referencedLine)
    }

    /// What the engine appends after the REFERENCED line (the actions-outcome block) is not the owner's words.
    func testTrailingBlocksAfterReferencedAreNotBody() {
        let stored = "hi\n\nREFERENCED: jira:PAY-1 \"PAY-1\"\n\nACTIONS SINCE YOUR LAST MESSAGE:\n- approved x"
        XCTAssertEqual(ChatOwnerText.displayParts(stored).body, "hi")
    }

    /// A REFERENCED-looking line the composer never makes stays text: nothing dropped, no chip.
    func testAMalformedReferencedLineIsText() {
        let stored = "look at this\n\nREFERENCED: not a well formed item"
        let parts = ChatOwnerText.displayParts(stored)
        XCTAssertNil(parts.referencedLine)
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertEqual(parts.body, stored)
    }

    /// A look-alike the composer escaped (zero-width space) reads back as the owner typed it.
    func testAnEscapedLookAlikeIsTheOwnersText() {
        let typed = "Use skill triage: load it with load_skill first."
        let parts = ChatOwnerText.displayParts("\u{200B}" + typed)
        XCTAssertNil(parts.skill)
        XCTAssertEqual(parts.body, typed)
    }
}
