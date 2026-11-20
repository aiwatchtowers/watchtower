import Foundation
import GRDB

/// What an Idea finder batch card shows under an idea's title: its two newest
/// mentions as quotes and the newest mention's source.
package struct IdeaBatchCardFacts: Equatable {
    /// The two newest mentions (by `said_at, id`), newest first, as
    /// `<author>: “<quote>”` joined with " · "; each quote cut at 200
    /// characters with "…". "" when the idea has no mentions.
    package let quote: String
    /// The newest mention's `IdeaMention.Source.label`; "" without mentions.
    package let sourceLabel: String

    package init(quote: String, sourceLabel: String) {
        self.quote = quote
        self.sourceLabel = sourceLabel
    }

    private static let quoteLimit = 200

    package static func read(_ db: Database, ideaID: Int) throws -> Self {
        let newest = try IdeaMention.fetchAll(db, sql: """
            SELECT * FROM idea_mentions WHERE idea_id = ? ORDER BY said_at DESC, id DESC LIMIT 2
            """, arguments: [ideaID])
        let lines = newest.map { mention -> String in
            let text: String = mention.quote.count > quoteLimit
                ? String(mention.quote.prefix(quoteLimit)) + "…"
                : mention.quote
            return "\(mention.author): “\(text)”"
        }
        return Self(quote: lines.joined(separator: " · "), sourceLabel: newest.first?.sourceKind.label ?? "")
    }
}
