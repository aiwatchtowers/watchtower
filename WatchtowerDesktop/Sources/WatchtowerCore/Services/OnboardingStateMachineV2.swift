import Foundation
import Observation

/// Onboarding v2's steps: Goals → Connect → About you → done. Persisted by
/// raw string under its own key, so no value can be mistaken for a legacy
/// `OnboardingStep` integer.
package enum OnboardingV2Step: String, CaseIterable, Sendable {
    case purpose
    case connect
    case aboutYou
    case complete

    /// The step indicator's label; nil for `.complete`.
    package var indicatorTitle: String? {
        switch self {
        case .purpose: "Goals"
        case .connect: "Connect"
        case .aboutYou: "About you"
        case .complete: nil
        }
    }

    /// The legacy flow's `onboarding_current_step` integer, mapped once: 7
    /// was `.complete`; 0…6 is someone stuck mid-way through the old
    /// eight-step flow, who starts over at Goals; anything else is unknown
    /// and also starts at Goals.
    package static func fromLegacy(_ raw: Int) -> Self {
        raw == 7 ? .complete : .purpose
    }
}

/// What decides which steps run, read when moving on.
package struct OnboardingRoute: Equatable, Sendable {
    package var goals: Set<OnboardingGoal>
    package var hasSlackAccount: Bool

    package init(goals: Set<OnboardingGoal>, hasSlackAccount: Bool) {
        self.goals = goals
        self.hasSlackAccount = hasSlackAccount
    }

    /// Connect is skipped when no chosen goal needs a source (Development
    /// alone, or nothing picked); About you when no Slack account is
    /// connected (its people pickers are Slack users).
    package func skips(_ step: OnboardingV2Step) -> Bool {
        switch step {
        case .connect: goals.isSubset(of: [.development])
        case .aboutYou: !hasSlackAccount
        case .purpose, .complete: false
        }
    }

    /// The first step after `step` this route runs.
    package func step(after step: OnboardingV2Step) -> OnboardingV2Step {
        let all = OnboardingV2Step.allCases
        guard let index = all.firstIndex(of: step) else { return .complete }
        return all[(index + 1)...].first { !skips($0) } ?? .complete
    }

    /// The indicator: Goals · Connect · About you, About you left out when
    /// it will be skipped.
    package var indicatorSteps: [OnboardingV2Step] {
        [.purpose, .connect] + (skips(.aboutYou) ? [] : [.aboutYou])
    }
}

/// Onboarding v2 progress, persisted in UserDefaults under
/// `onboarding_v2_step`. On first use it reads the legacy
/// `onboarding_current_step` once (`OnboardingV2Step.fromLegacy`) and drops
/// the legacy keys — so it must not run beside the legacy
/// `OnboardingStateMachine`, which still owns them until the old flow goes.
@MainActor
@Observable
package final class OnboardingStateMachineV2 {
    package static let stepKey = "onboarding_v2_step"
    package static let legacyStepKey = "onboarding_current_step"
    /// The legacy flow's background-sync and chat flags; v2 has neither.
    package static let legacyFlagKeys = ["onboarding_sync_completed", "onboarding_chat_finished"]

    package private(set) var currentStep: OnboardingV2Step

    @ObservationIgnored private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.stepKey) {
            currentStep = OnboardingV2Step(rawValue: raw) ?? .purpose
            return
        }
        currentStep = defaults.object(forKey: Self.legacyStepKey) == nil
            ? .purpose
            : OnboardingV2Step.fromLegacy(defaults.integer(forKey: Self.legacyStepKey))
        defaults.removeObject(forKey: Self.legacyStepKey)
        Self.legacyFlagKeys.forEach(defaults.removeObject(forKey:))
        persist()
    }

    /// Moves to the next step `route` runs.
    package func advance(route: OnboardingRoute) {
        goTo(route.step(after: currentStep))
    }

    package func goTo(_ step: OnboardingV2Step) {
        currentStep = step
        persist()
    }

    /// "Run setup again" from Settings.
    package func reset(to step: OnboardingV2Step = .purpose) {
        goTo(step)
    }

    private func persist() {
        defaults.set(currentStep.rawValue, forKey: Self.stepKey)
    }
}
