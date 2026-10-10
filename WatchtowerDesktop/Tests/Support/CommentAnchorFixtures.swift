import Foundation

/// `WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json`, the review
/// comment anchors Core's `CommentAnchor` and the Kit's port must both
/// produce (mobile POC spec §6.2). Read from the repo, so the Desktop and
/// Kit tests run one file.
package struct CommentAnchorFixtures: Decodable {
    package struct Heading: Decodable, Equatable {
        package let offset: Int
        package let title: String

        package init(offset: Int, title: String) {
            self.offset = offset
            self.title = title
        }
    }

    /// UTF-16 units into `text`.
    package struct Selection: Decodable {
        package let location: Int
        package let length: Int
    }

    package struct Anchor: Decodable, Equatable {
        package let quote: String
        package let prefix: String
        package let suffix: String
        package let heading: String

        package init(quote: String, prefix: String, suffix: String, heading: String) {
            self.quote = quote
            self.prefix = prefix
            self.suffix = suffix
            self.heading = heading
        }
    }

    package struct Case: Decodable {
        package let name: String
        /// The review ask's `doc_snapshot` (for a clipped case, what the
        /// hub's cut leaves of it).
        package let markdown: String
        /// The plain text Core renders `markdown` to.
        package let text: String
        package let headings: [Heading]
        package let selection: Selection
        package let anchor: Anchor
        /// The snapshot the hub cut at its cap (`OwnerAskSlice.clipSnapshot`).
        package let docClipped: Bool

        private enum CodingKeys: String, CodingKey {
            case name, markdown, text, headings, selection, anchor
            case docClipped = "doc_clipped"
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            markdown = try c.decode(String.self, forKey: .markdown)
            text = try c.decode(String.self, forKey: .text)
            headings = try c.decode([Heading].self, forKey: .headings)
            selection = try c.decode(Selection.self, forKey: .selection)
            anchor = try c.decode(Anchor.self, forKey: .anchor)
            docClipped = try c.decodeIfPresent(Bool.self, forKey: .docClipped) ?? false
        }
    }

    package let contextLength: Int
    package let cases: [Case]

    private enum CodingKeys: String, CodingKey {
        case contextLength = "context_length"
        case cases
    }

    package static func load() throws -> Self {
        let repo = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent("WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
