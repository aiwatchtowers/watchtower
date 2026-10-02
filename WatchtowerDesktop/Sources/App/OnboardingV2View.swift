import GRDB
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
    @State private var dbOpener = OnboardingDatabaseOpener()
    @State private var isFinishing = false
    @State private var finishError: String?

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
                    onBack: { appState.onboarding.goTo(.purpose) },
                    onContinue: { await leave(.connect, route: appState.onboardingRoute) }
                )
            case .aboutYou:
                placeholderStep(.aboutYou, text: "Tell Watchtower about your role and team.")
            case .complete:
                EmptyView()
            }

            if let finishError {
                Text(finishError)
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
                    appState.onboarding.goTo(appState.onboardingRoute.skips(.connect) ? .purpose : .connect)
                }
                    .disabled(isFinishing)
                Spacer()
                Button("Continue") {
                    Task { await leave(step, route: appState.onboardingRoute) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFinishing)
            }
        }
    }

    /// Moves past `step`: to the next step the route runs, or — when none is
    /// left — through the completion sequence.
    private func leave(_ step: OnboardingV2Step, route: OnboardingRoute) async {
        // Connect's account sheets need the database, which Goals' Continue
        // has just created on a fresh install.
        if step == .purpose, route.step(after: step) == .connect {
            if let failure = await appState.openDatabaseForOnboarding() {
                finishError = "Could not open the database: \(failure)"
                return
            }
        }
        finishError = nil
        guard route.step(after: step) == .complete else {
            appState.onboarding.advance(route: route)
            return
        }
        await finish()
    }

    /// `OnboardingCompletion.finish` with `onboarding_done` written on its
    /// own (`OnboardingProfileWriter.later`); About you replaces it with its
    /// answers.
    private func finish() async {
        guard !isFinishing else { return }
        isFinishing = true
        finishError = nil
        defer { isFinishing = false }
        await OnboardingCompletion.finish(
            markOnboardingDone: {
                let manager: DatabaseManager
                if let open = appState.databaseManager {
                    manager = open
                } else {
                    switch await dbOpener.open() {
                    case .success(let opened):
                        manager = opened
                    case .failure(let error):
                        finishError = "Could not open the database: \(error.localizedDescription)"
                        return false
                    }
                }
                do {
                    try await manager.dbPool.write { db in try OnboardingProfileWriter.later(db) }
                    return true
                } catch {
                    finishError = "Could not finish setup: \(error.localizedDescription)"
                    return false
                }
            },
            startPipelines: {
                appState.backgroundTaskManager.startPipelines(
                    legacyPeople: appState.analysisLegacyMode,
                    disabledFeatures: appState.featureManager.disabledFeatureIDs
                )
            },
            completeOnboarding: { appState.completeOnboarding() },
            onRetry: onRetry
        )
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
