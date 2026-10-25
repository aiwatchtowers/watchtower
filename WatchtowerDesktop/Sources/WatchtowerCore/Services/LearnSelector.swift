import Foundation

/// How a card reads (design §9.4, §9.7).
package enum LearnVariant: Equatable, Sendable {
    case normal
    /// NEW IN X.Y; `version` is the badge's "X.Y".
    case new(version: String)
    /// UPDATED IN X.Y: the owner saw a card this one replaces; `text` is the
    /// card's `changed`, or its `text` without one.
    case updated(version: String, text: String)

    var isFresh: Bool { self != .normal }

    var isUpdated: Bool {
        if case .updated = self { return true }
        return false
    }
}

/// A card as Home or See all shows it.
package struct LearnPick: Equatable, Identifiable, Sendable {
    package let card: LearnCard
    package let variant: LearnVariant
    /// false = the button becomes Turn on / Connect.
    package let requirementMet: Bool
    /// How it was seen before this read, `.inUse` when this read records it,
    /// nil while unseen.
    package let seenHow: LearnSeenHow?

    package var id: String { card.id }
    package var seen: Bool { seenHow != nil }
    /// Show again is offered only for a card the owner dismissed or acted on:
    /// an in-use card would be recorded again at the next read.
    package var canShowAgain: Bool { seenHow == .gotIt || seenHow == .action }
}

/// A See all section: the new cards, or one area's cards.
package struct LearnSection: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// "New in X.Y".
        case new(version: String)
        case area(LearnArea)
    }

    package let kind: Kind
    package let cards: [LearnPick]

    package var seenCount: Int { cards.filter(\.seen).count }
    package var total: Int { cards.count }
}

/// What the Learn zone shows after one read.
package struct LearnSelection: Equatable, Sendable {
    /// Up to three unseen cards; empty with `total > 0` = everything seen.
    package let home: [LearnPick]
    package let seenCount: Int
    /// Every live card.
    package let total: Int
    /// Cards whose `done_when` is true, to write as `in_use` rows.
    package let recordInUse: [String]
    /// See all: the new section (when any) first, then the areas in §9.3
    /// order; every card, seen ones flagged.
    package let sections: [LearnSection]
}

/// What the selector reads.
package struct LearnSelectorInput: Sendable {
    package var catalog: LearnCatalog
    /// `learn_seen`, by id (rows for ids no longer in the guide are ignored).
    package var seen: [String: LearnSeenHow]
    /// The signals that are true now.
    package var signals: Set<LearnSignal>
    /// The `requires` values that are met (`feature:ideas`, `source:jira`).
    package var metRequirements: Set<String>
    package var goals: Set<OnboardingGoal>
    /// `LearnVersionPolicy.newAfter`: cards whose `since` is newer are new;
    /// nil = nothing is new.
    package var newAfter: LearnVersion?

    package init(
        catalog: LearnCatalog,
        seen: [String: LearnSeenHow] = [:],
        signals: Set<LearnSignal> = [],
        metRequirements: Set<String> = [],
        goals: Set<OnboardingGoal> = [],
        newAfter: LearnVersion? = nil
    ) {
        self.catalog = catalog
        self.seen = seen
        self.signals = signals
        self.metRequirements = metRequirements
        self.goals = goals
        self.newAfter = newAfter
    }
}

/// Picks the Learn zone's cards (design §9.4–§9.7). Pure.
package enum LearnSelector {
    package static let homeCount = 3

    package static func select(_ input: LearnSelectorInput) -> LearnSelection {
        let cards = input.catalog.cards
        var recordInUse: [String] = []
        let picks = cards.map { card -> LearnPick in
            let variant = variant(of: card, input: input)
            var seenHow = input.seen[card.id]
            // An updated card shows even while its feature is in use: the change is the point.
            if seenHow == nil, !variant.isUpdated, let signal = card.doneWhen, input.signals.contains(signal) {
                recordInUse.append(card.id)
                seenHow = .inUse
            }
            let met = card.requires.isEmpty || input.metRequirements.contains(card.requires)
            return LearnPick(card: card, variant: variant, requirementMet: met, seenHow: seenHow)
        }
        let ordered = sorted(picks, goals: input.goals)
        return LearnSelection(
            home: home(ordered.filter { !$0.seen }),
            seenCount: picks.filter(\.seen).count,
            total: picks.count,
            recordInUse: recordInUse,
            sections: sections(ordered: ordered, guideOrder: picks))
    }

    /// `replaces` already holds the whole chain (`internal/learn` expands it
    /// through `retired.txt`).
    private static func variant(of card: LearnCard, input: LearnSelectorInput) -> LearnVariant {
        if card.replaces.contains(where: { input.seen[$0] != nil }) {
            return .updated(version: LearnVersion.badge(card.since), text: card.changed.isEmpty ? card.text : card.changed)
        }
        if let after = input.newAfter, let since = LearnVersion(card.since), since > after {
            return .new(version: since.majorMinor)
        }
        return .normal
    }

    /// New and updated first, then the goals' areas, then the other areas
    /// (§9.3 order each), basics → next → power, met requirements first,
    /// guide order last.
    private static func sorted(_ picks: [LearnPick], goals: Set<OnboardingGoal>) -> [LearnPick] {
        let goalAreas = Set(goals.map(LearnArea.init(goal:)))
        let areaOrder = LearnArea.allCases.filter(goalAreas.contains) + LearnArea.allCases.filter { !goalAreas.contains($0) }
        let areaRank = Dictionary(uniqueKeysWithValues: areaOrder.enumerated().map { ($1, $0) })
        return stableSorted(picks) { pick in
            [pick.variant.isFresh ? 0 : 1, areaRank[pick.card.area] ?? 0, levelRank(pick.card.level),
             pick.requirementMet ? 0 : 1]
        }
    }

    /// Sorted by `key`, ties kept in their order.
    private static func stableSorted(_ picks: [LearnPick], key: (LearnPick) -> [Int]) -> [LearnPick] {
        let keyed = picks.enumerated().map { (key: key($1) + [$0], pick: $1) }
        let ordered = keyed.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        return ordered.map(\.pick)
    }

    private static func levelRank(_ level: LearnLevel) -> Int {
        LearnLevel.allCases.firstIndex(of: level) ?? 0
    }

    /// At most one card per area, unless the unseen cards are all in one area.
    private static func home(_ unseen: [LearnPick]) -> [LearnPick] {
        guard Set(unseen.map(\.card.area)).count > 1 else { return Array(unseen.prefix(homeCount)) }
        var areas = Set<LearnArea>()
        return Array(unseen.filter { areas.insert($0.card.area).inserted }.prefix(homeCount))
    }

    private static func sections(ordered: [LearnPick], guideOrder: [LearnPick]) -> [LearnSection] {
        var result: [LearnSection] = []
        let fresh = ordered.filter(\.variant.isFresh)
        if !fresh.isEmpty {
            let newest = fresh.compactMap { LearnVersion($0.card.since) }.max()
            result.append(LearnSection(
                kind: .new(version: newest?.majorMinor ?? LearnVersion.badge(fresh[0].card.since)),
                cards: fresh))
        }
        for area in LearnArea.allCases {
            // By level, met requirements first, then guide order.
            let inArea = guideOrder.filter { $0.card.area == area }
            let cards = stableSorted(inArea) { [levelRank($0.card.level), $0.requirementMet ? 0 : 1] }
            if !cards.isEmpty { result.append(LearnSection(kind: .area(area), cards: cards)) }
        }
        return result
    }
}
