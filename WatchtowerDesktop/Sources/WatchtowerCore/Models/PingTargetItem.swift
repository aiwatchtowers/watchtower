import Foundation

/// A person to contact about a Jira issue — used by WhoToPingView.
package struct PingTargetItem: Identifiable, Codable {
    package var id: String { "\(slackUserID)_\(reason)" }
    package let slackUserID: String
    package let displayName: String
    /// Raw reason key: "assignee", "assignee_blocker", "expert", "reporter",
    /// "slack_participant", "decision_maker".
    package let reason: String

    package init(slackUserID: String, displayName: String, reason: String) {
        self.slackUserID = slackUserID
        self.displayName = displayName
        self.reason = reason
    }

    package enum CodingKeys: String, CodingKey {
        case slackUserID = "slack_user_id"
        case displayName = "display_name"
        case reason
    }

    /// Human-readable label for the reason.
    package var reasonLabel: String {
        switch reason {
        case "assignee":           return "Assignee"
        case "assignee_blocker":   return "Blocker assignee"
        case "expert":             return "Expert"
        case "reporter":           return "Reporter"
        case "slack_participant":  return "Active in Slack"
        case "decision_maker":    return "Decision maker"
        default:                   return reason.capitalized
        }
    }
}
