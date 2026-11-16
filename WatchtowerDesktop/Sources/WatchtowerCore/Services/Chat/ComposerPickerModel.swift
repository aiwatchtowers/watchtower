import ChatWire
import Foundation
import Observation
import WatchtowerChatText

package struct ComposerPickerItem: Equatable, Identifiable, Sendable {
    package let id: String
    package let icon: String
    package let title: String
    package let subtitle: String
}

/// The composer's `@` and `/` picker state (spec §6.2): what is open, the
/// rows, the selection, and the mentions and skill picked for the current
/// draft. The search and the skill catalog are injected (the main chat asks
/// the engine: `entity_search`, `skills_list`); a result that arrives after
/// the text moved on is dropped.
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
    private var skillHits: [ChatSkill] = []
    private var suppressedStart: Int?
    private let searchMentions: @MainActor (String) async -> [MentionCandidate]
    private let skills: @MainActor () async -> [ChatSkill]
    /// The skill catalog, read once.
    private var skillCatalog: [ChatSkill]?
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    package init(
        searchMentions: @escaping @MainActor (String) async -> [MentionCandidate],
        skills: @escaping @MainActor () async -> [ChatSkill] = { [] }
    ) {
        self.searchMentions = searchMentions
        self.skills = skills
    }

    package var isOpen: Bool { mode != .none && !items.isEmpty }

    /// Called on every text/caret change. A `/` at the start of the draft
    /// opens the skill picker; otherwise an active `@` opens the mention one.
    /// The rows follow once the search answers.
    package func update(text: String, cursor: Int) {
        generation += 1
        let current = generation
        search?.cancel()
        if let trigger = MentionTokenizer.activeSkill(text: text, cursor: cursor) {
            guard trigger.start != suppressedStart else {
                close()
                return
            }
            suppressedStart = nil
            mode = .skill(query: trigger.query)
            search = Task { [weak self] in
                guard let self else { return }
                let catalog = await self.catalog()
                guard current == self.generation else { return }
                self.skillHits = catalog.filter { trigger.query.isEmpty || $0.name.hasPrefix(trigger.query) }
                self.items = self.skillHits.map {
                    ComposerPickerItem(id: "skill:" + $0.name, icon: "wand.and.stars", title: $0.name,
                                       subtitle: $0.description)
                }
                self.mentionHits = []
                self.selectedIndex = 0
            }
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
        mode = .mention(query: trigger.query)
        let searchMentions = searchMentions
        search = Task { [weak self] in
            let hits = await searchMentions(trigger.query)
            guard let self, current == self.generation else { return }
            self.mentionHits = hits
            self.items = hits.map(Self.item(for:))
            self.skillHits = []
            self.selectedIndex = 0
        }
    }

    /// Returns once the search the last `update` started answered (tests).
    package func searchSettled() async {
        await search?.value
    }

    private func catalog() async -> [ChatSkill] {
        if let skillCatalog { return skillCatalog }
        let loaded = await skills()
        if !loaded.isEmpty { skillCatalog = loaded }
        return loaded
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
        generation += 1
        search?.cancel()
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
        case .jira, .linear: icon = "ticket"
        case .target: icon = "target"
        case .track: icon = "point.topleft.down.to.point.bottomright.curvepath"
        }
        return ComposerPickerItem(id: candidate.id, icon: icon, title: candidate.label, subtitle: candidate.detail)
    }
}
