import Foundation

/// The one Approve rule of an agent action's card, shared by the card
/// (`AgentActionCardView.canApprove`) and Needs approval's **Approve All**
/// (`NeedsApprovalGroups.isBulkApprovable`).
package enum AgentActionApproval {
    /// The tool whose card refuses Approve on args it cannot draw.
    package static let confluenceEditTool = "edit_confluence_page"

    /// An `edit_confluence_page` row is approvable only when its args hold a
    /// non-empty `changes` list — the card cannot show any other edit, and
    /// approving it would write a page the owner never saw (F7). Every other
    /// tool is. Remembered per action id while its args stay the same: the
    /// args carry the whole page, and the card and the list are drawn often.
    package static func canApproveOnCard(_ action: AgentAction) -> Bool {
        guard action.tool == confluenceEditTool else { return true }
        if let cached = readable.withLock({ $0[action.id] }), cached.args == action.argsJSON { return cached.value }
        let value = hasReadableChanges(action.args)
        readable.withLock { cache in
            if cache.count >= 512 { cache.removeAll() }
            cache[action.id] = (action.argsJSON, value)
        }
        return value
    }

    /// The rule on args already decoded: a non-empty `changes` list. The
    /// card's preview build (`AgentActionCardView.confluenceEdit`) checks
    /// its one decode with it, so the card never decodes the args twice.
    package static func hasReadableChanges(_ args: [String: Any]) -> Bool {
        (args["changes"] as? [[String: Any]]).map { !$0.isEmpty } ?? false
    }

    private static let readable = ArgsMemo<Bool>()
}
