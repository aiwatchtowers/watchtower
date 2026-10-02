import SwiftUI
import WatchtowerCore

/// Onboarding v2: Goals → Connect → About you, driven by
/// `AppState.onboarding` (`OnboardingStateMachineV2`). About you is a
/// placeholder with Back/Continue until its own step lands; leaving the last
/// step the route runs finishes onboarding.
struct OnboardingV2View: View {
    /// Re-runs the app bootstrap once onboarding completes (`NavigationRoot`
    /// passes `AppState.reinitializeAfterOnboarding()`).
    let onRetry: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            BannerImage(maxWidth: 200)
            OnboardingStepIndicator(
                steps: appState.onboardingRoute.indicatorSteps,
                current: appState.onboarding.currentStep
            )

            switch appState.onboarding.currentStep {
            case .purpose:
                OnboardingGoalsStepView { route in await leave(.purpose, route: route) }
            case .connect:
                OnboardingConnectStepView(
                    onBack: { back(to: .purpose) },
                    onContinue: { await leave(.connect, route: appState.onboardingRoute) }
                )
            case .aboutYou:
                placeholderStep(.aboutYou, text: "Tell Watchtower about your role and team.")
            case .complete:
                EmptyView()
            }

            if let error = appState.onboardingStepError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 28)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func placeholderStep(_ step: OnboardingV2Step, text: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Back") {
                    back(to: appState.onboardingRoute.skips(.connect) ? .purpose : .connect)
                }
                .disabled(appState.isFinishingOnboarding)
                Spacer()
                Button("Continue") {
                    Task { await leave(step, route: appState.onboardingRoute) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isFinishingOnboarding)
            }
        }
    }

    private func back(to step: OnboardingV2Step) {
        appState.clearOnboardingStepError()
        appState.onboarding.goTo(step)
    }

    private func leave(_ step: OnboardingV2Step, route: OnboardingRoute) async {
        await appState.leaveOnboardingStep(step, route: route, onRetry: onRetry)
    }
}

/// Goals · Connect · About you, the steps the route skips left out; every
/// step up to the current one is lit.
struct OnboardingStepIndicator: View {
    let steps: [OnboardingV2Step]
    let current: OnboardingV2Step

    var body: some View {
        let currentIndex = steps.firstIndex(of: current) ?? steps.count
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                HStack(spacing: 5) {
                    Circle()
                        .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(step.indicatorTitle ?? "")
                        .foregroundStyle(index == currentIndex ? .primary : .secondary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 30, height: 1)
                }
            }
        }
        .font(.caption)
    }
}
