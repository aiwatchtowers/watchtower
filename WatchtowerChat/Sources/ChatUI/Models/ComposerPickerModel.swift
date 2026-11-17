import ChatWire
import Foundation
import Observation
import WatchtowerChatText

/// One row of the `@` or `/` picker.
public struct ComposerPickerItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let icon: String
    public let title: String
    public let subtitle: String

    public init(id: String, icon: String, title: String, subtitle: String) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }
}

/// The composer's `@` and `/` picker state (spec §6.2), on the Mac and the phone: what is open, the rows, the
/// selection, and the mentions and skill picked for the current draft. The search and the skill catalog are injected
/// (the engine's `entity_search` and `skills_list`); a result that arrives after the text moved on is dropped.
@MainActor
@Observable
public final class ComposerPickerModel {
    public enum Mode: Equatable, Sendable {
        case none
        case mention(query: String)
        case skill(query: String)
    }

    /// The kinds an `@` mention can point at; other hits (a Jira project, a Confluence space) are pinned, not
    /// mentioned, and never offered.
    public static let mentionKinds: Set = ["person", "channel", "jira", "linear", "target", "track"]

    public private(set) var mode: Mode = .none
    public private(set) var items: [ComposerPickerItem] = []
    public private(set) var selectedIndex = 0
    /// The mentions picked into the draft, in pick order.
    public var mentions: [ChatCompose.Mention] = []
    /// The `/`-picked skill for the current draft, or nil.
    public var skill: String?

    private var mentionHits: [ChatEntityHit] = []
    private var skillHits: [ChatSkill] = []
    private var suppressedStart: Int?
    private let searchEntities: @MainActor (String) async -> [ChatEntityHit]
    private let skills: @MainActor () async -> [ChatSkill]
    /// The skill catalog, read once.
    private var skillCatalog: [ChatSkill]?
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(
        searchEntities: @escaping @MainActor (String) async -> [ChatEntityHit],
        skills: @escaping @MainActor () async -> [ChatSkill] = { [] }
    ) {
        self.searchEntities = searchEntities
        self.skills = skills
    }

    public var isOpen: Bool { mode != .none && !items.isEmpty }

    /// Called on every text/caret change. A `/` at the start of the draft opens the skill picker; otherwise an
    /// active `@` opens the mention one. The rows follow once the search answers.
    public func update(text: String, cursor: Int) {
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
        let searchEntities = searchEntities
        search = Task { [weak self] in
            let hits = await searchEntities(trigger.query)
            guard let self, current == self.generation else { return }
            self.mentionHits = hits.filter { Self.mention(for: $0) != nil }
            self.items = self.mentionHits.map(Self.item(for:))
            self.skillHits = []
            self.selectedIndex = 0
        }
    }

    /// Returns once the search the last `update` started answered (tests, shots).
    public func searchSettled() async {
        await search?.value
    }

    private func catalog() async -> [ChatSkill] {
        if let skillCatalog { return skillCatalog }
        let loaded = await skills()
        if !loaded.isEmpty { skillCatalog = loaded }
        return loaded
    }

    /// Up, Down, Enter/Tab and Esc go to the open picker first; a closed picker consumes nothing.
    public func handle(_ key: ComposerPickerKey, text: String, cursor: Int) -> ComposerKeyResult {
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

    /// Inserts the row's mention (or, in skill mode, sets the picked skill and removes the `/query` text) in place
    /// of the active trigger.
    public func accept(index: Int, text: String, cursor: Int) -> ComposerEdit? {
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
                  let trigger = MentionTokenizer.activeMention(text: text, cursor: cursor),
                  let mention = Self.mention(for: mentionHits[index]) else { return nil }
            let edit = MentionTokenizer.replace(trigger, in: text, cursor: cursor, with: "@\(mention.label) ")
            if !mentions.contains(mention) { mentions.append(mention) }
            close()
            return edit
        case .none:
            return nil
        }
    }

    public func removeMention(_ mention: ChatCompose.Mention) {
        mentions.removeAll { $0 == mention }
    }

    public func clearSkill() {
        skill = nil
    }

    /// After a send: the draft is gone, so are its mentions and skill.
    public func reset() {
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

    /// The picked mentions whose `@Label` is still in the text, in pick order, without duplicates: only those go
    /// with the message.
    public static func liveMentions(text: String, mentions: [ChatCompose.Mention]) -> [ChatCompose.Mention] {
        var seen = Set<String>()
        return mentions.filter { text.contains("@\($0.label)") && seen.insert("\($0.kind):\($0.id)").inserted }
    }

    /// A hit as a mention: nil for a kind that cannot be mentioned. A newline in the label becomes a space (the
    /// engine's REFERENCED line and the `@Label` text are one line each).
    public static func mention(for hit: ChatEntityHit) -> ChatCompose.Mention? {
        guard mentionKinds.contains(hit.kind) else { return nil }
        let label = hit.label.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return ChatCompose.Mention(kind: hit.kind, id: hit.id, label: label)
    }

    public static func icon(forKind kind: String) -> String {
        switch kind {
        case "person": "person.crop.circle"
        case "channel": "number"
        case "jira", "linear": "ticket"
        case "target": "target"
        case "track": "point.topleft.down.to.point.bottomright.curvepath"
        default: "at"
        }
    }

    static func item(for hit: ChatEntityHit) -> ComposerPickerItem {
        let label = mention(for: hit)?.label ?? hit.label
        return ComposerPickerItem(id: "\(hit.kind):\(hit.id)", icon: icon(forKind: hit.kind), title: label,
                                  subtitle: hit.detail)
    }
}
