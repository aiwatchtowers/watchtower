import Foundation

// The Learn Watchtower zone's catalog: the cards `watchtower guide learn
// --json` reads out of the user guide (`internal/learn`), and the seen state
// the Desktop keeps in `learn_seen`.

/// What part of the work a card helps with, in the order Home and See all
/// list them (design §9.3).
package enum LearnArea: String, CaseIterable, Decodable, Sendable {
    case communication
    case meetings
    case tasks
    case development
    case assistant
    case planning
    case automations
    case iphone
    case setup

    /// The area an onboarding goal puts first.
    package init(goal: OnboardingGoal) {
        switch goal {
        case .workCommunication: self = .communication
        case .meetings: self = .meetings
        case .tasksAndJira: self = .tasks
        case .development: self = .development
        }
    }
}

/// Basics first, power last.
package enum LearnLevel: String, CaseIterable, Decodable, Sendable {
    case basics
    case next
    case power
}

package enum LearnKind: String, CaseIterable, Decodable, Sendable {
    case feature
    case tip
    case shortcut
}

/// A card's `done_when`: a use of the feature the app reads from its own
/// state. Go↔Swift dual path with `internal/learn` (`learn.Signals`); a test
/// on each side pins the same list (plan D2).
package enum LearnSignal: String, CaseIterable, Sendable {
    case meetingRecorded = "meeting.recorded"
    case chatUsed = "chat.used"
    case workbenchBound = "workbench.bound"
    case reactionUsed = "reaction.used"
    case automationCreated = "automation.created"
    case memoryOn = "memory.on"
    case calendarConnected = "calendar.connected"
    case jiraConnected = "jira.connected"
    case linearConnected = "linear.connected"
    case confluenceConnected = "confluence.connected"
    case iphonePaired = "iphone.paired"
    case dictationUsed = "dictation.used"
}

/// How a card became seen; the `learn_seen.how` CHECK values.
package enum LearnSeenHow: String, CaseIterable, Sendable {
    case gotIt = "got_it"
    case action
    case inUse = "in_use"
}

/// One card. Optional strings are `""` on the wire.
package struct LearnCard: Decodable, Equatable, Identifiable, Sendable {
    package let id: String
    package let title: String
    package let text: String
    package let area: LearnArea
    package let level: LearnLevel
    package let kind: LearnKind
    /// `X.Y.Z` (or `next` before the release stamps it).
    package let since: String
    /// `nav:` / `connect:` / `turnOn:` / `chat:` / `hotkey:`; `""` = Read more.
    package let action: String
    /// What changed, shown on the updated variant; `""` = show `text`.
    package let changed: String
    /// nil when absent, or a value this build does not know (no signal).
    package let doneWhen: LearnSignal?
    /// `feature:<id>` or `source:<name>`; `""` = nothing required.
    package let requires: String
    package let replaces: [String]
    /// Guide path (`features/home.md`) and section slug, for Read more.
    package let page: String
    package let anchor: String
    /// The key's label for a `hotkey:` action (⌘/); `""` otherwise.
    package let hotkeyLabel: String

    enum CodingKeys: String, CodingKey {
        case id, title, text, area, level, kind, since, action, changed, requires, replaces, page, anchor
        case doneWhen = "done_when"
        case hotkeyLabel = "hotkey_label"
    }

    package init(
        id: String,
        title: String,
        text: String,
        area: LearnArea,
        level: LearnLevel,
        kind: LearnKind,
        since: String,
        action: String = "",
        changed: String = "",
        doneWhen: LearnSignal? = nil,
        requires: String = "",
        replaces: [String] = [],
        page: String = "",
        anchor: String = "",
        hotkeyLabel: String = ""
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.area = area
        self.level = level
        self.kind = kind
        self.since = since
        self.action = action
        self.changed = changed
        self.doneWhen = doneWhen
        self.requires = requires
        self.replaces = replaces
        self.page = page
        self.anchor = anchor
        self.hotkeyLabel = hotkeyLabel
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        area = try c.decode(LearnArea.self, forKey: .area)
        level = try c.decode(LearnLevel.self, forKey: .level)
        kind = try c.decode(LearnKind.self, forKey: .kind)
        since = try c.decode(String.self, forKey: .since)
        action = try c.decode(String.self, forKey: .action)
        changed = try c.decode(String.self, forKey: .changed)
        doneWhen = LearnSignal(rawValue: try c.decode(String.self, forKey: .doneWhen))
        requires = try c.decode(String.self, forKey: .requires)
        replaces = try c.decode([String].self, forKey: .replaces)
        page = try c.decode(String.self, forKey: .page)
        anchor = try c.decode(String.self, forKey: .anchor)
        hotkeyLabel = try c.decode(String.self, forKey: .hotkeyLabel)
    }
}

/// `watchtower guide learn --json`: the live cards and every id some card
/// replaces (retired ids never come back).
package struct LearnCatalog: Decodable, Equatable, Sendable {
    package let cards: [LearnCard]
    package let retired: [String]

    package init(cards: [LearnCard], retired: [String] = []) {
        self.cards = cards
        self.retired = retired
    }
}
