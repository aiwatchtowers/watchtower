import XCTest
import WatchtowerChatText
@testable import WatchtowerCore

/// `internal/chatengine/testdata/compose_cases.json` pins Go's
/// `chatengine.ComposeOwnerText` (and the artifact comment message) to the
/// Swift composer the Mac sends with today: `ChatQuoteReply.compose` then
/// `ChatTurnComposer.compose`, or `ArtifactCommentMessage.compose` (dual
/// path, pinned from both sides).
final class ComposeFixtureTests: XCTestCase {
    private struct Mention: Decodable {
        let kind: String
        let id: String
        let label: String
    }

    private struct Quote: Decodable {
        let text: String
        let comment: String?
    }

    private struct Comment: Decodable {
        let quote: String
        let heading: String
        let body: String
    }

    private struct Artifact: Decodable {
        let title: String
        let key: String
        let version: Int
        let comments: [Comment]
    }

    private struct Case: Decodable {
        let name: String
        let text: String
        let skill: String
        let mentions: [Mention]
        let quotes: [Quote]
        let artifact: Artifact?
        let stored: String
    }

    private static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chatengine/testdata/compose_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    /// The stored row of `ArtifactComment` built from a fixture comment.
    private static func comment(_ c: Comment, index: Int, artifact: Artifact) throws -> ArtifactComment {
        let row: [String: Any] = [
            "id": index + 1, "conversation_id": 1, "artifact_key": artifact.key, "artifact_version": artifact.version,
            "body": c.body, "anchor_quote": c.quote, "anchor_prefix": "", "anchor_suffix": "",
            "anchor_heading": c.heading, "status": "open", "created_at": 1.0
        ]
        return try JSONDecoder().decode(ArtifactComment.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testComposeFixtureMatchesGo() throws {
        let all = try Self.cases()
        XCTAssertGreaterThanOrEqual(all.count, 10)
        for c in all {
            let got: String
            if let artifact = c.artifact {
                let comments = try artifact.comments.enumerated().map {
                    try Self.comment($0.element, index: $0.offset, artifact: artifact)
                }
                let message = try XCTUnwrap(ArtifactCommentMessage.compose(
                    title: artifact.title, key: artifact.key, version: artifact.version, comments: comments))
                got = ChatTurnComposer.compose(text: message, skill: nil, mentions: [])
            } else {
                let quotes = c.quotes.map { ChatQuoteDraft(quote: $0.text, comment: $0.comment ?? "") }
                let text = ChatQuoteReply.compose(quotes: quotes, typed: c.text) ?? c.text
                let mentions = try c.mentions.map {
                    MentionCandidate(kind: try XCTUnwrap(MentionCandidate.Kind(rawValue: $0.kind)),
                                     ref: $0.id, label: $0.label, detail: "")
                }
                got = ChatTurnComposer.compose(text: text, skill: c.skill.isEmpty ? nil : c.skill, mentions: mentions)
            }
            XCTAssertEqual(got, c.stored, c.name)
        }
    }
}
