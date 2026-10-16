import Foundation

/// Where the session's notes sit on the tree under review: stored lines on the
/// same tree, else the quote located in the current text; lost notes are absent.
package enum ReviewNotePlacement {
    package static func place(
        // swiftlint:disable:next large_tuple
        _ notes: [(id: Int64, quote: String, startLine: Int, endLine: Int, treeSHA: String)],
        currentTree: String,
        textFor: (Int64) -> String?
    ) -> [Int64: ReviewCommentAnchor.Placement] {
        var out: [Int64: ReviewCommentAnchor.Placement] = [:]
        for note in notes {
            if note.treeSHA == currentTree {
                out[note.id] = ReviewCommentAnchor.Placement(startLine: note.startLine, endLine: note.endLine)
            } else if let text = textFor(note.id),
                      let found = ReviewCommentAnchor.locate(quote: note.quote, prefix: "", suffix: "", in: text) {
                out[note.id] = found
            }
        }
        return out
    }
}
