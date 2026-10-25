import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// Home's Learn zone (#718) on sample cards: a NEW card first, a card whose
/// feature is off (Turn on), a hotkey card; and the See all sheet with a
/// seen row, an in-use row and an UPDATED card.
@MainActor
enum LearnShotFixtures {
    private static func card(
        _ id: String,
        _ title: String,
        _ text: String,
        _ area: LearnArea,
        level: LearnLevel = .basics,
        kind: LearnKind = .feature,
        since: String = "0.24.0",
        action: String = "",
        changed: String = "",
        requires: String = "",
        replaces: [String] = [],
        hotkeyLabel: String = ""
    ) -> LearnCard {
        LearnCard(id: id, title: title, text: text, area: area, level: level, kind: kind, since: since,
                  action: action, changed: changed, requires: requires, replaces: replaces,
                  page: "features/home.md", anchor: id, hotkeyLabel: hotkeyLabel)
    }

    private static let cards = [
        card("automations", "Automations", "Recipes the daemon runs for you: press **+** and pick **Watch for something**.",
             .automations, since: "0.25.0", action: "nav:automations"),
        card("catch-up", "Catch-Up", "Back from a day off? Press **Catch Up** for one recap of what you missed.",
             .communication, action: "nav:catchUp"),
        card("digests", "Channel digests", "A summary per channel after each sync.", .communication),
        card("ask-anywhere", "Ask from anywhere", "Press **⌘/** on any screen to ask the assistant about what you see.",
             .assistant, kind: .shortcut, action: "hotkey:help", hotkeyLabel: "⌘/"),
        card("ideas", "Ideas from your chats", "Ideas and decisions mined from Slack, in one list.", .planning,
             level: .next, action: "nav:ideas", requires: "feature:ideas"),
        card("dictation-key", "Dictation", "One key for dictation and Quick Capture.", .meetings, level: .next,
             kind: .tip, since: "0.25.0", changed: "Now **one key** for dictation and Quick Capture.",
             replaces: ["dictation-old"]),
        card("record", "Record a meeting", "Transcribed on this Mac; a recap and action items after the call.",
             .meetings),
        card("linear", "Linear boards", "Your Linear issues next to Jira.", .tasks, level: .next,
             action: "connect:linear"),
        card("voices", "Teach it voices", "Name speakers once; they're known next time.", .meetings, level: .power)
    ]

    static func selection(allSeen: Bool = false) -> LearnSelection {
        var seen: [String: LearnSeenHow] = ["digests": .gotIt, "dictation-old": .gotIt, "record": .inUse]
        if allSeen { cards.forEach { seen[$0.id] = .gotIt } }
        return LearnSelector.select(LearnSelectorInput(
            catalog: LearnCatalog(cards: cards), seen: seen, metRequirements: [],
            goals: [.workCommunication, .meetings], newAfter: LearnVersion(major: 0, minor: 24, patch: 0)))
    }

    /// The right column's zone on its own, at the column's width.
    static func zone(allSeen: Bool = false) -> some View {
        LearnZoneView(selection: selection(allSeen: allSeen), actions: .none)
            .frame(width: 400)
            .padding(Spacing.page)
    }

    static func sheet() -> some View {
        LearnAllSheet(selection: selection(), actions: .none) {}
    }
}
