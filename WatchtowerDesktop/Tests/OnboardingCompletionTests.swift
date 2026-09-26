import Testing
@testable import WatchtowerDesktop

/// `OnboardingCompletion.finish`'s entire contract is its fixed order and
/// its stop-on-failure gate, so both are pinned directly (spies recording
/// each closure firing), without a live SwiftUI environment, database, or
/// daemon.
@MainActor
@Suite("OnboardingCompletion")
struct OnboardingCompletionTests {
    @Test("finish() runs markOnboardingDone, startPipelines, completeOnboarding, onRetry in that fixed order, and returns true")
    func finishRunsInPinnedOrderOnSuccess() async {
        var order: [String] = []

        let result = await OnboardingCompletion.finish(
            markOnboardingDone: {
                // A real async DB write — yielding here proves the next
                // steps wait for it rather than racing ahead.
                await Task.yield()
                order.append("markOnboardingDone")
                return true
            },
            startPipelines: { order.append("startPipelines") },
            completeOnboarding: { order.append("completeOnboarding") },
            onRetry: { order.append("onRetry") }
        )

        #expect(order == ["markOnboardingDone", "startPipelines", "completeOnboarding", "onRetry"])
        #expect(result == true)
    }

    @Test("finish() stops after a failed markOnboardingDone: none of the later steps run, and it returns false")
    func finishStopsWhenMarkOnboardingDoneFails() async {
        // Without this gate, a failed DB write would still run
        // completeOnboarding() (clearing the persisted onboarding step)
        // while user_profile.onboarding_done never actually flipped — the
        // next launch would then reconcile against a still-false DB flag
        // and force the user through nearly the whole onboarding flow again.
        var order: [String] = []

        let result = await OnboardingCompletion.finish(
            markOnboardingDone: {
                order.append("markOnboardingDone")
                return false
            },
            startPipelines: { order.append("startPipelines") },
            completeOnboarding: { order.append("completeOnboarding") },
            onRetry: { order.append("onRetry") }
        )

        #expect(order == ["markOnboardingDone"])
        #expect(result == false)
    }
}
