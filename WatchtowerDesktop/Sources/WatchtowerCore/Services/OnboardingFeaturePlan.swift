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
    /// Knowledge search is mechanical (no AI) and the chat leans on it. The
    /// registry's core entries (targets, chat) need no entry here — they have
    /// no switch at all.
    package static let alwaysOnFeatureIDs: Set<String> = ["knowledge-search"]

    /// Off whatever the goals are: Memory is still an experiment, opted into
    /// only by hand.
    package static let alwaysOffFeatureIDs: Set<String> = ["memory"]

    /// Development maps to nothing: Workbench, the chat, Knowledge search and
    /// Targets are always on. Meetings' calendar connection is the Connect
    /// step's business, not a feature switch.
    package static func featureIDs(for goal: OnboardingGoal) -> Set<String> {
        switch goal {
        case .workCommunication:
            // Slack Digests is load-bearing: Tracks and People Cards mine its
            // output and have no material without it.
            return [
                "secretary-inbox", "slack-digests", "tracks", "people-cards",
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

    /// Every feature whose state onboarding decides. Anything outside it
    /// (core entries, Confluence in search) keeps whatever state it has.
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
