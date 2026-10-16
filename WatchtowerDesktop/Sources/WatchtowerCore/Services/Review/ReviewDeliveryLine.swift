import Foundation

/// The line typed into a session after Send (spec §9) — the Swift twin of Go
/// `reviewdiff.DeliveryLine`, pinned by internal/reviewdiff/testdata/lines.
package enum ReviewDeliveryLine {
    package static func line(roundID: Int64, comments: Int) -> String {
        let noun = comments == 1 ? "comment" : "comments"
        return WorkbenchCommentPrompt.oneLine(
            "Review round #\(roundID) sent (\(comments) \(noun)) — read it with get_review \(roundID) using the watchtower-workbench skill."
        )
    }
}
