import Foundation

/// The fixed sequence that finishes onboarding, extracted from
/// `OnboardingView` so the ORDERING is unit-testable without a live SwiftUI
/// environment, database, or daemon. Both of the feature splash's exits
/// (Continue, "Keep everything on") call `finish`, binding `OnboardingView`'s
/// real dependencies as closures; tests pass spies instead.
enum OnboardingCompletion {
    /// Order is load-bearing: the DB `onboarding_done` flag must land before
    /// the pipelines that read it start, and the local state machine only
    /// flips to `.complete` (which swaps the whole UI away from onboarding)
    /// once everything else has already run — `onRetry` resumes AppState's
    /// normal flow last, after there is something real for it to resume into.
    ///
    /// `markOnboardingDone` reports whether the DB write actually succeeded.
    /// On `false`, `finish` stops right there — `startPipelines`,
    /// `completeOnboarding`, and `onRetry` never run, and the overall result
    /// is `false` — instead of the state machine silently believing
    /// onboarding is done while `user_profile.onboarding_done` never
    /// actually flipped: `completeOnboarding()` clears the persisted step,
    /// so the NEXT launch would otherwise reconcile against a still-false DB
    /// flag and force the user through nearly the whole flow again via
    /// `skipCompleted()`. The caller (the splash) is expected to show an
    /// inline retry instead of silently swallowing the failure.
    @MainActor
    @discardableResult
    static func finish(
        markOnboardingDone: () async -> Bool,
        startPipelines: () -> Void,
        completeOnboarding: () -> Void,
        onRetry: () -> Void
    ) async -> Bool {
        guard await markOnboardingDone() else { return false }
        startPipelines()
        completeOnboarding()
        onRetry()
        return true
    }
}
