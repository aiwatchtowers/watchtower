import Foundation

/// The write tool a Reply from an Inbox row proposes (Go `tools.InboxReplyTools`).
package enum InboxReplyTool: String, CaseIterable, Sendable {
    case slack = "send_slack_message"
    case jira = "add_jira_comment"
    case linear = "add_linear_comment"
}

/// An open Reply composer: the text typed and the last refusal.
package struct InboxReplyDraft: Equatable, Sendable {
    package var text = ""
    package var error: String?

    package init(text: String = "", error: String? = nil) {
        self.text = text
        self.error = error
    }
}

/// Reply from a row (inbox builder B, asks #445 and #451): the local
/// writer's tool and args for `watchtower actions propose` (no tower:
/// tests; Task 12 deletes it). Which rows draw **Reply…**, and whether a
/// reply already waits, are Go's ref facts (`reply`, `reply_waiting`).
package enum InboxReplyPolicy {
    /// The `context_type` a Reply proposal carries (Go `db.InboxItemContextType`).
    package static let contextType = "inbox_item"

    /// The tool by trigger type: Slack's four → `send_slack_message`, Jira's
    /// two → `add_jira_comment`, Linear's two → `add_linear_comment`. Mail
    /// and every other trigger have no write path; a Slack item without a
    /// permalink or a Jira/Linear item without its issue key has none either.
    package static func tool(for item: InboxItem) -> InboxReplyTool? {
        switch item.triggerType {
        case "mention", "dm", "thread_reply", "reaction":
            return item.permalink.isEmpty ? nil : .slack
        case "jira_assigned", "jira_comment_mention":
            return item.channelID.isEmpty ? nil : .jira
        case "linear_assigned", "linear_comment_mention":
            return item.channelID.isEmpty ? nil : .linear
        default:
            return nil
        }
    }

    /// The proposal's reason: "Reply from Waiting for me", "Reply from
    /// Messages", or the owner artifact's own title.
    package static func reason(host: String) -> String {
        "Reply from \(host)"
    }

    /// The tool's args bound to the item's own place: Slack its permalink
    /// (a message link replies in its thread; `send_slack_message` pins the
    /// recipient at propose time) and its account; Jira and Linear the issue
    /// key (Go resolves and pins the account at propose time). Nil when the
    /// item has no Reply.
    package static func args(for item: InboxItem, text: String, host: String) -> String? {
        guard let tool = tool(for: item) else { return nil }
        var args: [String: Any] = ["reason": reason(host: host)]
        switch tool {
        case .slack:
            args["channel"] = item.permalink
            args["text"] = text
            if let account = SlackAccountID.split(item.channelID)?.accountID {
                args["account_id"] = account
            }
        case .jira, .linear:
            args["key"] = item.channelID
            args["body"] = text
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// The argv of one Reply press: a proposal only, never `--approve`.
    package static func arguments(itemID: Int, tool: InboxReplyTool, args: String) -> [String] {
        [
            "actions", "propose", "--tool", tool.rawValue, "--surface", "inbox",
            "--context", "\(contextType):\(itemID)", "--args", args, "--json"
        ]
    }
}
