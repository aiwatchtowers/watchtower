/// A source card on onboarding's Connect step.
package enum OnboardingConnectSource: Equatable, Sendable {
    case slack
    /// One Google card for both: the sheet asks for the scopes the goals
    /// need.
    case google(mail: Bool, calendar: Bool)
    case jira
}

/// Which source cards the Connect step shows: only what the goals need.
package enum OnboardingConnectPlan {
    /// Slack and Google mail for Work communication, Google calendar for
    /// Meetings, Jira for Tasks & Jira, in that order. Development needs
    /// none (the route skips the step).
    package static func sources(for goals: Set<OnboardingGoal>) -> [OnboardingConnectSource] {
        var sources: [OnboardingConnectSource] = []
        let mail = goals.contains(.workCommunication)
        let calendar = goals.contains(.meetings)
        if mail { sources.append(.slack) }
        if mail || calendar { sources.append(.google(mail: mail, calendar: calendar)) }
        if goals.contains(.tasksAndJira) { sources.append(.jira) }
        return sources
    }

    /// The first Slack account in `after` that is not in `before` — the one
    /// the Add sheet just connected, whose roster the people load fetches.
    package static func newlyConnected(before: Set<Int>, after: [Int]) -> Int? {
        after.first { !before.contains($0) }
    }
}
