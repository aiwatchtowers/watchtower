import Foundation

/// The lines typed into a session after Send or Approve (spec §9; #964) —
/// the Swift twins of Go `reviewdiff.DeliveryLine` and `ApprovedLine`,
/// pinned by internal/reviewdiff/testdata/lines.
package enum ReviewDeliveryLine {
    package static func line(roundID: Int64, comments: Int) -> String {
        let noun = comments == 1 ? "comment" : "comments"
        return WorkbenchCommentPrompt.oneLine(
            "Review round #\(roundID) sent (\(comments) \(noun)) — read it with get_review \(roundID) using the watchtower-workbench skill."
        )
    }

    /// The line of a round the owner approved: it holds only the id.
    package static func approved(roundID: Int64) -> String {
        WorkbenchCommentPrompt.oneLine(
            "Review round #\(roundID) approved — the owner approved this branch; finish it the way your methodology says "
                + "(read get_review \(roundID) using the watchtower-workbench skill)."
        )
    }
}
