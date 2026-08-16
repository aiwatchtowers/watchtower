import Testing
@testable import WatchtowerDesktop

/// `OnboardingCompletion.finish` has no branching — its entire contract is
/// the fixed order it runs its four steps in, so that order is the one thing
/// worth pinning directly (spies recording each closure firing), without a
/// live SwiftUI environment, database, or daemon.
@MainActor
@Suite("OnboardingCompletion")
struct OnboardingCompletionTests {
    @Test("finish() runs markOnboardingDone, startPipelines, completeOnboarding, onRetry in that fixed order")
    func finishRunsInPinnedOrder() async {
        var order: [String] = []

        await OnboardingCompletion.finish(
            markOnboardingDone: {
                // A real async DB write — yielding here proves the next
                // steps wait for it rather than racing ahead.
                await Task.yield()
                order.append("markOnboardingDone")
            },
            startPipelines: { order.append("startPipelines") },
            completeOnboarding: { order.append("completeOnboarding") },
            onRetry: { order.append("onRetry") }
        )

        #expect(order == ["markOnboardingDone", "startPipelines", "completeOnboarding", "onRetry"])
    }
}
