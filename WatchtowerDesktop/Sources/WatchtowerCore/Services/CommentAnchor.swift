import Foundation

/// A comment's anchor on a document's RENDERED plain text (spec §6.3):
/// the selected quote, up to `contextLength` characters on either side, and
/// the nearest preceding heading. Task 15 adds `make` and `locate`.
package struct CommentAnchor: Equatable, Sendable {
    package static let contextLength = 64

    package var quote: String
    package var prefix: String
    package var suffix: String
    package var heading: String

    package init(quote: String, prefix: String, suffix: String, heading: String) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.heading = heading
    }
}
