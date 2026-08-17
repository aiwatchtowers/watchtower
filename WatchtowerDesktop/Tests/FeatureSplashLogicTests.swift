import Testing
@testable import WatchtowerDesktop

/// The splash's Continue path has exactly one decision in it — whether to go
/// on and finish onboarding after `apply()` returns — and getting it wrong
/// either traps a new user in onboarding or moves on over a failed apply.
/// Pinned here as a truth table, away from the SwiftUI environment the button
/// itself needs.
@Suite("FeatureSplashLogic")
struct FeatureSplashLogicTests {
    @Test("nothing staged, no error: finish")
    func finishesWhenNothingStagedAndNoError() {
        #expect(FeatureSplashLogic.shouldFinishAfterApply(hadPendingChanges: false, loadError: nil))
    }

    /// The case the predicate exists for: `apply()` returns without touching
    /// `loadError` when nothing was staged, so a leftover error from a failed
    /// `load()` is stale here. Reading it as an apply failure would trap the
    /// user on the splash with no way out.
    @Test("nothing staged, stale load error: finish anyway")
    func finishesWhenNothingStagedDespiteStaleLoadError() {
        #expect(FeatureSplashLogic.shouldFinishAfterApply(hadPendingChanges: false, loadError: "features list failed"))
    }

    @Test("changes staged and applied cleanly: finish")
    func finishesWhenStagedChangesApplied() {
        #expect(FeatureSplashLogic.shouldFinishAfterApply(hadPendingChanges: true, loadError: nil))
    }

    /// The only stop: the owner staged something, and `apply()` reported a
    /// failure for it. Stay on the splash so the error banner is visible and
    /// a second Continue can retry the still-pending remainder.
    @Test("changes staged, apply failed: do not finish")
    func doesNotFinishWhenStagedChangesFailed() {
        #expect(!FeatureSplashLogic.shouldFinishAfterApply(hadPendingChanges: true, loadError: "enable failed"))
    }
}
