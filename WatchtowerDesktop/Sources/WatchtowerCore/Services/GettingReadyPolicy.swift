import Foundation

/// Which Getting ready cards and source rows Home shows, and when the zone
/// is shown, collapsed to "Everything's ready", or gone. Pure: the clock and
/// the persisted memory come in, the memory to persist goes out.
package enum GettingReadyPolicy {
    /// The zone folds this long after it was first shown, whatever is still
    /// scheduled or failing (a feature can stay unready for days).
    package static let foldAfter: TimeInterval = 3 * 24 * 60 * 60

    /// `readiness` is P1's map; empty = not evaluated yet. A ready card stays
    /// in the zone until every card is ready or error (owner, ask #304).
    package static func step(
        readiness: [ReadinessFeature: Readiness],
        ownerKnown: Bool,
        memory: GettingReadyMemory,
        sawUnready: Bool,
        now: Date,
        briefingHour: Int,
        dayPlanHour: Int
    ) -> GettingReadyStep {
        let hidden = GettingReadyStep(zone: .hidden, memory: memory, sawUnready: sawUnready)
        // No flicker before the first evaluation.
        guard !readiness.isEmpty, !memory.hiddenByOwner else { return hidden }
        if memory.completedAt != nil {
            // Completed during this launch → "Everything's ready"; gone on the next.
            return sawUnready ? GettingReadyStep(zone: .allReady, memory: memory, sawUnready: sawUnready) : hidden
        }
        if let firstShownAt = memory.firstShownAt, now.timeIntervalSince(firstShownAt) > foldAfter { return hidden }

        var cards: [GettingReadyCard] = []
        var sourceRows: [GettingReadySourceRow] = []
        for feature in ReadinessFeature.allCases {
            let state = FeatureReadiness.honoringOwner(readiness[feature], of: feature, ownerKnown: ownerKnown)
            switch state {
            case .off:
                continue
            case .needsSource(let source):
                if let index = sourceRows.firstIndex(where: { $0.source == source }) {
                    sourceRows[index] = GettingReadySourceRow(
                        source: source, features: sourceRows[index].features + [feature])
                } else {
                    sourceRows.append(GettingReadySourceRow(source: source, features: [feature]))
                }
            default:
                cards.append(GettingReadyCard(
                    feature: feature,
                    copy: EmptyStateCopyTable.featureCard(feature, briefingHour: briefingHour, dayPlanHour: dayPlanHour),
                    readiness: state))
            }
        }
        // A Development-only install's lone knowledge-index card does not open the zone.
        guard cards.contains(where: { $0.feature.source != .none }) else { return hidden }

        var next = memory
        if cards.allSatisfy(\.isTerminal) {
            // An install that was already ready at first look never was getting ready.
            next.completedAt = now
            return GettingReadyStep(zone: sawUnready ? .allReady : .hidden, memory: next, sawUnready: sawUnready)
        }
        next.firstShownAt = memory.firstShownAt ?? now
        return GettingReadyStep(zone: .shown(cards: cards, sourceRows: sourceRows), memory: next, sawUnready: true)
    }
}
