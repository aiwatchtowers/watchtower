import Foundation
import WatchtowerKit

/// A comment or reply the Mac applied whose record the replica does not
/// have yet (#1192): the thread shows it in place, so it never vanishes
/// between the applied echo and the Mac's next publish.
struct PostedComment: Equatable {
    /// How long one is kept without its record (the Mac publishes a board
    /// write within seconds; a comment deleted meanwhile must not stay).
    static let keepFor: TimeInterval = 10 * 60

    /// The Mac's id (`result.comment_id`).
    let commentID: Int64
    /// The target of a new comment; nil for a reply.
    let targetID: Int64?
    /// The root of a reply; nil for a new comment.
    let rootID: Int64?
    let body: String
    let postedAt: Date

    /// Still waiting for its record at `now`.
    func isWaiting(in comments: [WorkbenchComment], now: Date) -> Bool {
        now.timeIntervalSince(postedAt) <= Self.keepFor && !comments.contains { $0.id == commentID }
    }
}
