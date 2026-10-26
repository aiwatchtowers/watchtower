/// A source card on onboarding's Connect step.
package enum OnboardingConnectSource: Equatable, Sendable {
    /// The `AllowedSources` name of the card's source.
    package var policySource: String {
        switch self {
        case .slack: "slack"
        case .google: "google"
        case .jira: "jira"
        case .linear: "linear"
        }
    }

    case slack
    /// One Google card. Connecting a Google account means mail and calendar
    /// both, whatever the goals (owner decision 2026-10-14, #740): the sheet
    /// opens with both scopes checked.
    case google
    case jira
    /// Linear, a peer of Jira on the same goal (spec §3.5).
    case linear
}

/// Which source cards the Connect step shows: only what the goals need.
package enum OnboardingConnectPlan {
    /// Slack and Google for Work communication, Google for Meetings, Jira
    /// and Linear for Tasks & Jira, in that order. Development needs
    /// none (the route skips the step). A source the organization's policy
    /// forbids (#608) is not offered.
    package static func sources(for goals: Set<OnboardingGoal>, policy: ManagedPolicy = .none) -> [OnboardingConnectSource] {
        var sources: [OnboardingConnectSource] = []
        let communication = goals.contains(.workCommunication)
        if communication { sources.append(.slack) }
        if communication || goals.contains(.meetings) { sources.append(.google) }
        if goals.contains(.tasksAndJira) { sources += [.jira, .linear] }
        return sources.filter { policy.sourceAllowed($0.policySource) }
    }

    /// The first Slack account in `after` that is not in `before` — the one
    /// the Add sheet just connected, whose roster the people load fetches.
    package static func newlyConnected(before: Set<Int>, after: [Int]) -> Int? {
        after.first { !before.contains($0) }
    }
}
