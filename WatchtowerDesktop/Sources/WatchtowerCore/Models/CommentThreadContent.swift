import Foundation

/// What `CommentThreadView` shows, independent of where the comments live
/// (project documents/targets, chat artifacts): the quoted text, a status
/// line (nil for an open thread) and the comments in order.
package struct CommentThreadContent: Identifiable, Equatable, Sendable {
    package struct Entry: Identifiable, Equatable, Sendable {
        package let id: Int64
        package let author: String
        package let body: String

        package init(id: Int64, author: String, body: String) {
            self.id = id
            self.author = author
            self.body = body
        }
    }

    package let id: Int64
    package let quote: String
    package let statusNote: String?
    package let entries: [Entry]

    package init(id: Int64, quote: String, statusNote: String?, entries: [Entry]) {
        self.id = id
        self.quote = quote
        self.statusNote = statusNote
        self.entries = entries
    }
}
