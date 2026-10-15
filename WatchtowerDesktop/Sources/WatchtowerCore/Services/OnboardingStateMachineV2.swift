import Foundation
import Observation

/// Onboarding v2's steps: Goals → Connect → done. Persisted by raw string
/// under its own key, so no value can be mistaken for the old flow's
/// `onboarding_current_step` integer. The raw values ARE the persisted
/// format: renaming a case sends everyone parked on it back to Goals.
package enum OnboardingV2Step: String, CaseIterable, Sendable {
    case purpose
    case connect
    case complete

    /// The raw value of the About you step, removed 2026-10-14 (#758): an
    /// install parked on it resumes at Connect, whose Continue finishes.
    package static let removedAboutYouRawValue = "aboutYou"

    /// The step a persisted raw value resumes at; nil for an unknown value.
    package init?(persisted raw: String) {
        if raw == Self.removedAboutYouRawValue {
            self = .connect
        } else {
            self.init(rawValue: raw)
        }
    }

    /// The step indicator's label; nil for `.complete`.
    package var indicatorTitle: String? {
        switch self {
        case .purpose: "Goals"
        case .connect: "Connect"
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

    package init(goals: Set<OnboardingGoal>) {
        self.goals = goals
    }

    /// Connect is skipped when no chosen goal needs a source (Development
    /// alone, or nothing picked).
    package func skips(_ step: OnboardingV2Step) -> Bool {
        switch step {
        case .connect: goals.isSubset(of: [.development])
        case .purpose, .complete: false
        }
    }

    /// The first step after `step` this route runs (`.complete` never
    /// skips, so there always is one; after `.complete` it stays there).
    package func step(after step: OnboardingV2Step) -> OnboardingV2Step {
        OnboardingV2Step.allCases.drop { $0 != step }.dropFirst().first { !skips($0) } ?? .complete
    }

    /// The indicator: Goals · Connect, Connect left out when this route
    /// skips it.
    package var indicatorSteps: [OnboardingV2Step] {
        OnboardingV2Step.allCases.filter { $0 != .complete && !skips($0) }
    }
}

/// Onboarding v2 progress, persisted in UserDefaults under
/// `onboarding_v2_step`. On first use it reads the legacy
/// `onboarding_current_step` once (`OnboardingV2Step.fromLegacy`) and drops
/// the legacy keys (the old eight-step flow is gone; an install upgraded
/// from it still carries them).
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
            currentStep = OnboardingV2Step(persisted: raw) ?? .purpose
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

    /// Moves on when the route skips the step a relaunch resumed on (e.g.
    /// Connect after the goals changed to Development only).
    package func settle(route: OnboardingRoute) {
        if route.skips(currentStep) { advance(route: route) }
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
