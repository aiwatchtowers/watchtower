/// What the owner wants Watchtower for — the checkboxes on onboarding's
/// Goals step. Each goal turns on a fixed set of features
/// (`OnboardingFeaturePlan.enabledFeatureIDs(for:)`).
package enum OnboardingGoal: String, CaseIterable, Sendable {
    case workCommunication
    case tasksAndJira
    case meetings
    case development
}

/// The onboarding goals → feature set mapping, pure so it can be pinned as a
/// table. Feature ids are the `internal/features/registry.go` ids verbatim.
package enum OnboardingFeaturePlan {
    /// Toggleable features onboarding switches on whatever the goals are:
    /// Knowledge search and Attention detection are mechanical (no AI);
    /// the chat leans on the first, Inbox and Catch-Up on the second
    /// (owner decision 2026-10-03, #283). Settings → Features still toggles
    /// both. The registry's core entries (targets, chat) need no entry
    /// here — they have no switch at all.
    package static let alwaysOnFeatureIDs: Set<String> = ["knowledge-search", "secretary-inbox"]

    /// Off whatever the goals are: Memory is still an experiment, opted into
    /// only by hand.
    package static let alwaysOffFeatureIDs: Set<String> = ["memory"]

    /// Development maps to nothing: Workbench, the chat, Knowledge search,
    /// Attention detection and Targets are always on. Meetings' calendar connection is the Connect
    /// step's business, not a feature switch.
    package static func featureIDs(for goal: OnboardingGoal) -> Set<String> {
        switch goal {
        case .workCommunication:
            // Slack Digests is load-bearing: Tracks and People Cards mine its
            // output and have no material without it.
            return [
                "slack-digests", "tracks", "people-cards",
                "briefing", "day-plan", "ideas", "reaction-commands"
            ]
        case .tasksAndJira:
            return ["stream-digests", "next-step"]
        case .meetings:
            return ["briefing"] // meeting prep rides the daily briefing
        case .development:
            return []
        }
    }

    /// Toggleable features onboarding deliberately leaves at whatever state
    /// they have: Confluence in search does nothing until a space is picked
    /// in Settings. Every non-core registry id is either managed or listed
    /// here — `OnboardingFeaturePlanTests` checks it against
    /// `internal/features/registry.go`, so a new feature must be classified.
    package static let unmanagedFeatureIDs: Set<String> = ["knowledge-connectors"]

    /// Every feature whose state onboarding decides. Anything outside it
    /// (core entries, `unmanagedFeatureIDs`) keeps whatever state it has.
    package static let managedFeatureIDs: Set<String> = OnboardingGoal.allCases.reduce(
        alwaysOnFeatureIDs.union(alwaysOffFeatureIDs)
    ) { $0.union(featureIDs(for: $1)) }

    /// The managed features the Customize screen shows a switch for — the
    /// always-on ones are listed in its "Always on" row instead.
    package static let customizableFeatureIDs: Set<String> = managedFeatureIDs.subtracting(alwaysOnFeatureIDs)

    /// The managed features `goals` turn on; every other managed feature is
    /// off.
    package static func enabledFeatureIDs(for goals: Set<OnboardingGoal>) -> Set<String> {
        goals.reduce(alwaysOnFeatureIDs) { $0.union(featureIDs(for: $1)) }
    }
}

/// Onboarding's feature choice: derived from the goals until the owner flips
/// a switch on the Customize screen, frozen from then on — a goal checked or
/// unchecked afterwards no longer moves any feature, until `resetToGoals()`.
package struct OnboardingFeatureSelection: Equatable, Sendable {
    package var goals: Set<OnboardingGoal>
    /// The owner's hand-picked set; nil while the goals decide.
    private var customEnabledIDs: Set<String>?

    package init(goals: Set<OnboardingGoal> = []) {
        self.goals = goals
    }

    /// "Run setup again": the selection that reproduces `enabledIDs` (the
    /// managed features on right now), so Continue changes nothing the owner
    /// did not change. Goals whose features are exactly what is on; among
    /// several such combinations (Development and Meetings add no feature of
    /// their own beyond Work communication's), the one closest to
    /// `savedGoals`. When no combination matches — features toggled by hand
    /// in Settings — the last goals with the current set as a manual pick
    /// ("Features customized").
    package static func current(
        enabledIDs: Set<String>,
        savedGoals: Set<OnboardingGoal>
    ) -> Self {
        let enabled = enabledIDs.intersection(OnboardingFeaturePlan.managedFeatureIDs)
        let matching = allGoalCombinations.filter { OnboardingFeaturePlan.enabledFeatureIDs(for: $0) == enabled }
        let closest = matching.max { lhs, rhs in
            closeness(lhs, to: savedGoals) < closeness(rhs, to: savedGoals)
        }
        if let closest { return Self(goals: closest) }
        // The goals whose features overlap the set most (fewest extras,
        // then closest to the saved goals), with the set as a manual pick.
        let nearest = allGoalCombinations.max { lhs, rhs in
            overlapScore(lhs, enabled: enabled, saved: savedGoals) < overlapScore(rhs, enabled: enabled, saved: savedGoals)
        } ?? savedGoals
        var selection = Self(goals: nearest)
        selection.customEnabledIDs = enabled
        return selection
    }

    private static let allGoalCombinations: [Set<OnboardingGoal>] = {
        let goals = OnboardingGoal.allCases
        return (0..<(1 << goals.count)).map { mask in
            Set(goals.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        }
    }()

    private static func overlapScore(
        _ goals: Set<OnboardingGoal>,
        enabled: Set<String>,
        saved: Set<OnboardingGoal>
    ) -> (overlap: Int, extras: Int, closeness: Int) {
        let ids = OnboardingFeaturePlan.enabledFeatureIDs(for: goals)
        return (ids.intersection(enabled).count, -ids.subtracting(enabled).count, closeness(goals, to: saved))
    }

    /// Goals in both minus goals in only one: ties keep `saved` itself on top.
    private static func closeness(_ goals: Set<OnboardingGoal>, to saved: Set<OnboardingGoal>) -> Int {
        goals.intersection(saved).count - goals.symmetricDifference(saved).count
    }

    package var isCustomized: Bool { customEnabledIDs != nil }

    /// The managed features to enable; every other id in
    /// `OnboardingFeaturePlan.managedFeatureIDs` is to be disabled.
    package var enabledFeatureIDs: Set<String> {
        customEnabledIDs ?? OnboardingFeaturePlan.enabledFeatureIDs(for: goals)
    }

    package func isEnabled(_ id: String) -> Bool {
        enabledFeatureIDs.contains(id)
    }

    /// A manual switch flip. Ignores ids onboarding does not manage, so a
    /// stray id can never reach the apply step.
    package mutating func setFeature(_ id: String, enabled: Bool) {
        guard OnboardingFeaturePlan.customizableFeatureIDs.contains(id) else { return }
        var ids = enabledFeatureIDs
        if enabled {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        customEnabledIDs = ids
    }

    /// Drops the manual picks; the goals decide again.
    package mutating func resetToGoals() {
        customEnabledIDs = nil
    }
}
