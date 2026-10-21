import Foundation

/// One of an Inbox card's own buttons (`automation_outputs.actions_json`,
/// Go `db.InboxAction`). A Reply's `data` stays in Go: the CLI reads it back
/// from the stored card, never from the Desktop.
package struct InboxCardAction: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// Opens the URL, after `InboxCardLinkPolicy` allows it at press time.
        case link(URL)
        /// The first message for AI Chat, put in the composer and not sent.
        case chat(String)
        case agent(task: String, workbench: WorkbenchRef?)
        case reply(value: String)
    }

    /// An Agent action's workbench: its id, or its name.
    package enum WorkbenchRef: Equatable, Sendable {
        case id(Int64)
        case name(String)
    }

    /// The action's position in the stored array: what `automations reply
    /// --action` takes, which a dropped action before it does not shift.
    package let index: Int
    package let label: String
    package let kind: Kind
    package let primary: Bool

    package init(index: Int, label: String, kind: Kind, primary: Bool) {
        self.index = index
        self.label = label
        self.kind = kind
        self.primary = primary
    }

    /// The card's buttons, in stored order. Tolerant of a newer or damaged
    /// column: an unknown kind or a missing or unusable field drops that
    /// action, and anything but a JSON array is no buttons at all.
    package static func decode(_ actionsJSON: String) -> [Self] {
        guard let items = (try? JSONSerialization.jsonObject(with: Data(actionsJSON.utf8))) as? [Any] else {
            return []
        }
        return items.enumerated().compactMap { index, item in
            guard let object = item as? [String: Any],
                  let label = object["label"] as? String, !label.isEmpty,
                  let kind = kind(of: object) else { return nil }
            return Self(index: index, label: label, kind: kind, primary: object["primary"] as? Bool ?? false)
        }
    }

    private static func kind(of object: [String: Any]) -> Kind? {
        switch object["kind"] as? String {
        case "link":
            guard let text = object["open"] as? String, let url = URL(string: text), url.scheme != nil else { return nil }
            return .link(url)
        case "chat":
            guard let text = object["chat"] as? String, !text.isEmpty else { return nil }
            return .chat(text)
        case "agent":
            guard let agent = object["agent"] as? [String: Any],
                  let task = agent["task"] as? String, !task.isEmpty else { return nil }
            return .agent(task: task, workbench: workbenchRef(agent["workbench"]))
        case "reply":
            guard let value = object["reply"] as? String else { return nil }
            return .reply(value: value)
        default:
            return nil
        }
    }

    /// A JSON integer is an id, a string a name; anything else is none.
    private static func workbenchRef(_ value: Any?) -> WorkbenchRef? {
        if let name = value as? String { return name.isEmpty ? nil : .name(name) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let id = Int64(exactly: number.doubleValue) else { return nil }
        return .id(id)
    }

    /// What the card's Reply buttons can do now: a press already made wins,
    /// then the recipe's state (the CLI refuses a recipe that cannot run).
    package static func replyState(_ card: AutomationOutputCard) -> InboxReplyState {
        if card.pressedAction != nil { return .sent(runID: card.pressedRunID) }
        switch card.recipeState {
        case .runnable: return .ready
        case .needsConfirmation: return .needsConfirmation
        case .disabled: return .off
        case .parseError: return .unreadable
        }
    }
}

/// The Reply buttons of one card: one press per card ("Sent — run #N").
package enum InboxReplyState: Equatable, Sendable {
    case ready
    /// Pressed; `runID` is nil when the queued run was since deleted.
    case sent(runID: Int64?)
    case needsConfirmation
    case off
    case unreadable
}
