import Foundation

/// The fixed sequence that finishes onboarding, kept apart so the ORDERING
/// is unit-testable without a live SwiftUI environment, database, or daemon.
/// `AppState.leaveOnboardingStep` binds the real dependencies as closures;
/// tests pass spies instead.
enum OnboardingCompletion {
    /// Order is load-bearing: the DB `onboarding_done` flag must land before
    /// the daemon (whose first cycle runs every pipeline) starts, and the local state machine only
    /// flips to `.complete` (which swaps the whole UI away from onboarding)
    /// once everything else has already run — `onRetry` resumes AppState's
    /// normal flow last, after there is something real for it to resume into.
    ///
    /// `markOnboardingDone` reports whether the DB write actually succeeded.
    /// On `false`, `finish` stops right there — `startDaemon`,
    /// `completeOnboarding`, and `onRetry` never run, and the overall result
    /// is `false` — instead of the state machine silently believing
    /// onboarding is done while `user_profile.onboarding_done` never
    /// actually flipped (`.complete` is persisted locally, so the divergence
    /// would otherwise be invisible on this machine and only resurface after
    /// a defaults wipe or on another install). The caller shows the failure
    /// and leaves the step where it is, so its button retries.
    @MainActor
    @discardableResult
    static func finish(
        markOnboardingDone: () async -> Bool,
        startDaemon: () async -> Void,
        completeOnboarding: () -> Void,
        onRetry: () -> Void
    ) async -> Bool {
        guard await markOnboardingDone() else { return false }
        await startDaemon()
        completeOnboarding()
        onRetry()
        return true
    }
}
