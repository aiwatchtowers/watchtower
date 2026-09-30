import Foundation

/// Re-anchors an artifact's comments on its latest version (pure; the model
/// applies the plan in one write). Open and sent comments follow the text:
/// found → they move onto this version, gone → outdated. Resolved comments
/// only get a highlight when their quote is still there; outdated ones are
/// never re-located, so a passage that comes back later does not silently
/// re-attach an old comment.
package enum ArtifactCommentReanchor {
    package struct Plan: Equatable, Sendable {
        /// Comment id → its range (UTF-16) in the version's rendered text.
        package var ranges: [Int64: NSRange] = [:]
        /// Live comments found on a version other than the one they were anchored on.
        package var moved: [Int64] = []
        /// Live comments whose quote is gone.
        package var lost: [Int64] = []

        package init(ranges: [Int64: NSRange] = [:], moved: [Int64] = [], lost: [Int64] = []) {
            self.ranges = ranges
            self.moved = moved
            self.lost = lost
        }

        package var isNoOp: Bool { moved.isEmpty && lost.isEmpty }
    }

    package static func plan(_ comments: [ArtifactComment], text: String, version: Int) -> Plan {
        var plan = Plan()
        for comment in comments where comment.status != .outdated {
            if let found = comment.anchor.locate(in: text) {
                plan.ranges[comment.id] = NSRange(found, in: text)
                if comment.isLive, comment.artifactVersion != version { plan.moved.append(comment.id) }
            } else if comment.isLive {
                plan.lost.append(comment.id)
            }
        }
        return plan
    }
}
