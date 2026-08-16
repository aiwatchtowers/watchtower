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
    @MainActor
    static func finish(
        markOnboardingDone: () async -> Void,
        startPipelines: () -> Void,
        completeOnboarding: () -> Void,
        onRetry: () -> Void
    ) async {
        await markOnboardingDone()
        startPipelines()
        completeOnboarding()
        onRetry()
    }
}
