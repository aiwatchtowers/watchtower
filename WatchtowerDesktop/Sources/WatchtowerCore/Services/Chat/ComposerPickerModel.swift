import Foundation
import Observation

package enum ComposerPickerKey: Sendable {
    case up, down, accept, dismiss
}

/// What a key did: `consumed == false` lets the text view handle it (Enter
/// sends, Esc stops); `edit` is a text change to apply with its caret.
package struct ComposerKeyResult: Equatable, Sendable {
    package let consumed: Bool
    package let edit: ComposerEdit?

    package init(consumed: Bool, edit: ComposerEdit?) {
        self.consumed = consumed
        self.edit = edit
    }
}

package struct ComposerPickerItem: Equatable, Identifiable, Sendable {
    package let id: String
    package let icon: String
    package let title: String
    package let subtitle: String
}

/// The composer's `@` picker state (spec §6.2): what is open, the rows, the
/// selection, and the mentions picked for the current draft. Lives on
/// `ChatViewModel` (so a draft's mentions survive navigation with it); the
/// search is injected so tests run without a database.
@MainActor
@Observable
package final class ComposerPickerModel {
    package enum Mode: Equatable, Sendable {
        case none
        case mention(query: String)
        case skill(query: String)
    }

    package private(set) var mode: Mode = .none
    package private(set) var items: [ComposerPickerItem] = []
    package private(set) var selectedIndex = 0
    package private(set) var mentions: [MentionCandidate] = []
    /// The `/`-picked skill for the current draft, or nil.
    package private(set) var skill: String?

    private var mentionHits: [MentionCandidate] = []
    private var skillHits: [SkillSummary] = []
    private var suppressedStart: Int?
    private let searchMentions: (String) -> [MentionCandidate]
    private let skills: () -> [SkillSummary]

    package init(
        searchMentions: @escaping (String) -> [MentionCandidate],
        skills: @escaping () -> [SkillSummary] = { [] }
    ) {
        self.searchMentions = searchMentions
        self.skills = skills
    }

    package var isOpen: Bool { mode != .none && !items.isEmpty }

    /// Called on every text/caret change. A `/` at the start of the draft
    /// opens the skill picker; otherwise an active `@` opens the mention one.
    package func update(text: String, cursor: Int) {
        if let trigger = MentionTokenizer.activeSkill(text: text, cursor: cursor) {
            guard trigger.start != suppressedStart else {
                close()
                return
            }
            suppressedStart = nil
            skillHits = skills().filter { trigger.query.isEmpty || $0.name.hasPrefix(trigger.query) }
            items = skillHits.map {
                ComposerPickerItem(id: "skill:" + $0.name, icon: "wand.and.stars", title: $0.name, subtitle: $0.description)
            }
            mentionHits = []
            mode = .skill(query: trigger.query)
            selectedIndex = 0
            return
        }
        guard let trigger = MentionTokenizer.activeMention(text: text, cursor: cursor) else {
            suppressedStart = nil
            close()
            return
        }
        guard trigger.start != suppressedStart else {
            close()
            return
        }
        suppressedStart = nil
        mentionHits = searchMentions(trigger.query)
        items = mentionHits.map(Self.item(for:))
        mode = .mention(query: trigger.query)
        selectedIndex = 0
    }

    package func handle(_ key: ComposerPickerKey, text: String, cursor: Int) -> ComposerKeyResult {
        guard isOpen else { return ComposerKeyResult(consumed: false, edit: nil) }
        switch key {
        case .up:
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return ComposerKeyResult(consumed: true, edit: nil)
        case .down:
            selectedIndex = (selectedIndex + 1) % items.count
            return ComposerKeyResult(consumed: true, edit: nil)
        case .dismiss:
            suppressedStart = (MentionTokenizer.activeSkill(text: text, cursor: cursor)
                ?? MentionTokenizer.activeMention(text: text, cursor: cursor))?.start
            close()
            return ComposerKeyResult(consumed: true, edit: nil)
        case .accept:
            return ComposerKeyResult(consumed: true, edit: accept(index: selectedIndex, text: text, cursor: cursor))
        }
    }

    /// Inserts the row's mention (or, in skill mode, sets the picked skill and
    /// removes the `/query` text) in place of the active trigger.
    package func accept(index: Int, text: String, cursor: Int) -> ComposerEdit? {
        switch mode {
        case .skill:
            guard skillHits.indices.contains(index),
                  let trigger = MentionTokenizer.activeSkill(text: text, cursor: cursor) else { return nil }
            skill = skillHits[index].name
            let edit = MentionTokenizer.replace(trigger, in: text, cursor: cursor, with: "")
            close()
            return edit
        case .mention:
            guard mentionHits.indices.contains(index),
                  let trigger = MentionTokenizer.activeMention(text: text, cursor: cursor) else { return nil }
            let candidate = mentionHits[index]
            let edit = MentionTokenizer.replace(trigger, in: text, cursor: cursor, with: candidate.insertionText + " ")
            if !mentions.contains(candidate) { mentions.append(candidate) }
            close()
            return edit
        case .none:
            return nil
        }
    }

    package func removeMention(_ candidate: MentionCandidate) {
        mentions.removeAll { $0 == candidate }
    }

    package func clearSkill() {
        skill = nil
    }

    /// After a send: the draft is gone, so are its mentions and skill.
    package func reset() {
        mentions = []
        skill = nil
        suppressedStart = nil
        close()
    }

    private func close() {
        mode = .none
        items = []
        mentionHits = []
        skillHits = []
        selectedIndex = 0
    }

    package static func item(for candidate: MentionCandidate) -> ComposerPickerItem {
        let icon: String
        switch candidate.kind {
        case .person: icon = "person.crop.circle"
        case .channel: icon = "number"
        case .jira: icon = "ticket"
        case .target: icon = "target"
        case .track: icon = "point.topleft.down.to.point.bottomright.curvepath"
        }
        return ComposerPickerItem(id: candidate.id, icon: icon, title: candidate.label, subtitle: candidate.detail)
    }
}
