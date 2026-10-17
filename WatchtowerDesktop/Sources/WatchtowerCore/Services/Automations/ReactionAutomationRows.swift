import Foundation

/// One `slack.reaction_added` recipe in the Reactions section: its name and
/// the emoji it listens for (nil when it takes any reaction).
package struct ReactionAutomationRow: Identifiable, Equatable, Sendable {
    package let id: Int64
    package let name: String
    package let emoji: String?

    package init(id: Int64, name: String, emoji: String?) {
        self.id = id
        self.name = name
        self.emoji = emoji
    }
}

package enum ReactionAutomationRows {
    /// The list's event recipes on `slack.reaction_added`, by name.
    package static func rows(from items: [AutomationListItem]) -> [ReactionAutomationRow] {
        items.compactMap { item -> ReactionAutomationRow? in
            let automation = item.automation
            guard automation.triggerKind == "event",
                  let event = AutomationTriggerText.eventSpec(specJSON: automation.triggerSpecJSON),
                  event.type == "slack.reaction_added" else { return nil }
            return ReactionAutomationRow(id: automation.id, name: automation.name, emoji: event.where["emoji"])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
