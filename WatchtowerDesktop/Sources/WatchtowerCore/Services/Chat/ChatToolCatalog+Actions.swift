import Foundation

/// Step labels/icons for the chat's write tools (spec 2026-09-26 §8). A write
/// call only records a proposal (AGENT-01), so the label says "Proposing…" —
/// except for the tools the owner commonly pre-approves locally, whose card
/// shows the real outcome. `args` is the raw JSON of the `tool_start` event.
extension ChatToolCatalog {
    package static func actionLabel(name: String, args: String) -> String? {
        let object = (args.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        func arg(_ key: String) -> String? {
            guard let value = object?[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        switch name {
        case "add_jira_comment":
            return arg("key").map { "Proposing a comment on \($0)" } ?? "Proposing a Jira comment"
        case "transition_jira_issue":
            guard let key = arg("key"), let status = arg("status") else { return "Proposing an issue transition" }
            return "Proposing \(key) → \(status)"
        case "assign_jira_issue":
            guard let key = arg("key"), let who = arg("assignee") else { return "Proposing an issue assignment" }
            return "Proposing to assign \(key) to \(who)"
        case "update_jira_issue":
            return arg("key").map { "Proposing an update to \($0)" } ?? "Proposing a Jira issue update"
        case "create_idea":
            return "Saving an idea"
        case "create_track":
            return arg("text").map { "Proposing a track: \($0)" } ?? "Proposing a track"
        case "remind_me":
            return arg("remind_at").map { "Setting a reminder for \($0)" } ?? "Setting a reminder"
        default:
            return nil
        }
    }

    package static func actionIcon(name: String) -> String? {
        switch name {
        case "add_jira_comment": return "text.bubble"
        case "transition_jira_issue": return "arrow.right.circle"
        case "assign_jira_issue": return "person.crop.circle.badge.plus"
        case "update_jira_issue": return "square.and.pencil"
        case "create_idea": return "lightbulb"
        case "create_track": return "binoculars"
        case "remind_me": return "alarm"
        default: return nil
        }
    }
}
