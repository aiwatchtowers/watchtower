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
        /// Proposes `create_target` (Inbox builder A). Only the Kit's decoder
        /// makes one: the context names the action's hash, which `decode`
        /// below cannot compute (WatchtowerCore links no Kit), so it drops
        /// a target action like an unknown kind.
        case target(Target)
    }

    /// A `target` action's task and the hash of the action as drawn (Go
    /// `blocks.ActionHash`, Swift `ArtifactAction.hash`).
    package struct Target: Equatable, Sendable {
        package let title: String
        package let intent: String?
        package let parent: Int64?
        package let hash: String

        package init(title: String, intent: String?, parent: Int64?, hash: String) {
            self.title = title
            self.intent = intent
            self.parent = parent
            self.hash = hash
        }
    }

    /// An Agent action's workbench: its id, or its name.
    package enum WorkbenchRef: Equatable, Sendable {
        case id(Int64)
        case name(String)
    }

    /// The action's press address: its index in the card's flattened action
    /// list (the card's own actions first, so for those the position in the
    /// stored array) — what `automations reply --action` takes, which a
    /// dropped action before it does not shift.
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
              number == NSNumber(value: number.int64Value) else { return nil }
        return .id(number.int64Value)
    }

    /// What the card's Reply buttons can do now: a press already made wins,
    /// then a removed recipe, then the recipe's state (the CLI refuses a
    /// recipe that cannot run).
    package static func replyState(_ card: AutomationOutputCard) -> InboxReplyState {
        if card.pressedAction != nil { return .sent(runID: card.pressedRunID) }
        if card.recipeRemoved { return .removed }
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
    /// The recipe's file is gone: nothing to confirm or turn on.
    case removed
}

/// The press of a `target` button (spec "The press"): `actions propose` of
/// `create_target` on the `inbox` surface, without `--approve` — one
/// pending row the owner approves in its approval card. The context names
/// the output, the button's flattened index and the drawn action's hash,
/// so a rewritten button is a new context.
package struct InboxTargetPress: Equatable, Sendable {
    package static let contextType = AgentActionQueries.buttonContextType

    package let contextID: String
    /// The `create_target` arguments: the drawn action's title, intent and
    /// parent, and a reason naming the card and its automation.
    package let argsJSON: String

    package init(card: AutomationOutputCard, index: Int, target: InboxCardAction.Target) {
        contextID = Self.contextID(outputID: card.id, index: index, hash: target.hash)
        let cardTitle = card.title.isEmpty ? "Automation output" : card.title
        var args: [String: Any] = [
            "text": target.title,
            "reason": "From the Inbox card \u{201C}\(cardTitle)\u{201D} of \(card.automationName)"
        ]
        if let intent = target.intent, !intent.isEmpty { args["intent"] = intent }
        if let parent = target.parent { args["parent_id"] = parent }
        // Strings and integers only: serialization cannot fail.
        let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes])
        argsJSON = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    /// `<output id>:<flattened index>:<action hash>`.
    package static func contextID(outputID: Int64, index: Int, hash: String) -> String {
        "\(outputID):\(index):\(hash)"
    }

    package var arguments: [String] {
        [
            "actions", "propose", "--tool", "create_target", "--surface", "inbox",
            "--context-type", Self.contextType, "--context-id", contextID,
            "--args", argsJSON, "--json"
        ]
    }
}
