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

        let (cards, sourceRows) = entries(
            readiness: readiness, ownerKnown: ownerKnown, briefingHour: briefingHour, dayPlanHour: dayPlanHour)
        // The zone opens on a card that reads a source, or on a Connect row a
        // feature the owner's goals switched on waits for (goals picked,
        // Connect skipped). Always-on features (Inbox) do not count, so a
        // Development-only install — the knowledge-index card, Connect rows
        // for the bare sources and Inbox — stays hidden.
        let sourcedCards = cards.contains { $0.feature.source != .none }
        let rowsUnlockFeatures = sourceRows.contains { $0.features.contains(where: isGoalSwitched) }
        guard sourcedCards || rowsUnlockFeatures else { return hidden }

        var next = memory
        // A rows-only zone is never complete: it stays until a source connects.
        if sourcedCards, cards.allSatisfy(\.isTerminal) {
            // An install that was already ready at first look never was getting ready.
            next.completedAt = now
            return GettingReadyStep(zone: sawUnready ? .allReady : .hidden, memory: next, sawUnready: sawUnready)
        }
        next.firstShownAt = memory.firstShownAt ?? now
        return GettingReadyStep(zone: .shown(cards: cards, sourceRows: sourceRows), memory: next, sawUnready: true)
    }

    /// Whether the feature has a switch the onboarding goals turn on (not a
    /// bare source, not always on).
    private static func isGoalSwitched(_ feature: ReadinessFeature) -> Bool {
        guard let id = feature.featureID else { return false }
        return !OnboardingFeaturePlan.alwaysOnFeatureIDs.contains(id)
    }

    /// The cards (every feature on and not waiting on a source) and the
    /// Connect rows (features grouped by the source they wait on), in
    /// pipeline order.
    private static func entries(
        readiness: [ReadinessFeature: Readiness],
        ownerKnown: Bool,
        briefingHour: Int,
        dayPlanHour: Int
    ) -> ([GettingReadyCard], [GettingReadySourceRow]) {
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
        return (cards, sourceRows)
    }
}
