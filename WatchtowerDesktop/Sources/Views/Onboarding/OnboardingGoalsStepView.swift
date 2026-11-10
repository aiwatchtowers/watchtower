import AppKit
import SwiftUI
import WatchtowerCore

extension OnboardingGoal {
    var title: String {
        switch self {
        case .workCommunication: "Work communication"
        case .tasksAndJira: "Tasks & Jira"
        case .meetings: "Meetings"
        case .development: "Development in Workbench"
        }
    }

    var pitch: String {
        switch self {
        case .workCommunication:
            "Back from a week off — Catch-Up in a minute. Every morning: what’s on fire and who’s waiting on you"
        case .tasksAndJira: "Jira issues and chat follow-ups in one list, with a suggested next step for each"
        case .meetings: "Before a meeting — context on people and topic. After — transcript and notes"
        case .development: "Claude Code works your folder’s board. No connections needed"
        }
    }
}

/// Onboarding step 1: goals, the assistant language and the AI agent
/// (#1521). Everything stateful is `AppState.onboardingGoals`; the sign-in
/// terminal and Choose the executable… go through the step's
/// `OnboardingSignInCoordinator`. `onContinue` gets the route Continue saved.
struct OnboardingGoalsStepView: View {
    let onContinue: (OnboardingRoute) async -> Void

    @Environment(AppState.self) private var appState
    @State private var signIn: OnboardingSignInCoordinator?

    private var model: OnboardingGoalsModel { appState.onboardingGoals }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isCustomizingFeatures {
                FeatureCustomizeView(selection: $model.selection) { model.isCustomizingFeatures = false }
            } else {
                goals
            }
        }
        .onAppear {
            let coordinator = signIn ?? OnboardingSignInCoordinator(model: model)
            signIn = coordinator
            Task { await coordinator.openIfNeeded() }
        }
        .task { await model.prepareGoalsStep(configuredLanguage: ConfigService().digestLanguage) }
        // Signed out after a check, or an update fixed the CLI: the terminal
        // opens by itself (once per agent, the model keeps count).
        .onChange(of: model.agentChoice.signInToOpen) { _, agent in
            guard agent != nil else { return }
            Task { await signIn?.openIfNeeded() }
        }
        // Any check that settles a running sign-in closes its terminal.
        .onChange(of: model.agentChoice.signIn) { _, state in
            if state != .running { signIn?.closeIfSettled() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.windowBecameActive() }
        }
        // Leaving the step (Continue, Cancel of a re-run, the window going)
        // ends the terminal's process; app quit is the coordinator's own.
        .onDisappear { signIn?.stop() }
    }

    private var goals: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Spacing.large) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text("What do you want Watchtower for?").font(.headline)
                Text("Pick any").font(.subheadline).foregroundStyle(.secondary)
            }
            OnboardingGoalCards(
                goals: model.selection.goals,
                developmentPitch: model.agentChoice.developmentPitch
            ) { model.toggleGoal($0) }
            customizeLine
            AssistantLanguageRow(selection: $model.language)
            agentSection
            Spacer(minLength: 0)
            OnboardingGoalsFooter(
                hint: model.agentChoice.continueHint,
                error: model.continueError ?? signIn?.pathError,
                canContinue: model.canContinue && !appState.isFinishingOnboarding,
                isContinuing: model.isContinuing,
                onContinue: submit
            )
            .padding(.top, Spacing.regular)
        }
        .disabled(model.isContinuing)
    }

    private var agentSection: some View {
        OnboardingAgentSection(
            choice: model.agentChoice,
            onPick: { agent in signIn?.pick(agent) },
            onCheckAgain: { Task { await signIn?.checkAgain() } },
            onChoosePath: { agent in Task { await signIn?.chooseExecutable(for: agent) } },
            onSignIn: { Task { await signIn?.open() } },
            onStopSignIn: { signIn?.stopByOwner() },
            signInTerminal: {
                guard let session = signIn?.session as? OnboardingSignInSession else { return AnyView(EmptyView()) }
                return AnyView(OnboardingSignInTerminal(session: session).id(ObjectIdentifier(session)))
            }
        )
    }

    private func submit() {
        Task {
            appState.clearOnboardingStepError()
            if let route = await model.submit(hasSlackAccount: appState.onboardingHasSlackAccount) {
                await onContinue(route)
            }
        }
    }

    @ViewBuilder
    private var customizeLine: some View {
        if model.selection.isCustomized {
            HStack(spacing: Spacing.small) {
                Text("Features customized ·").foregroundStyle(.secondary)
                Button("Reset") { model.selection.resetToGoals() }.buttonStyle(.link)
                Text("·").foregroundStyle(.secondary)
                Button("Customize features →") { model.isCustomizingFeatures = true }.buttonStyle(.link)
            }
            .font(.callout)
        } else {
            Button("Customize features →") { model.isCustomizingFeatures = true }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// The four goal cards, two per row.
struct OnboardingGoalCards: View {
    let goals: Set<OnboardingGoal>
    /// Replaces the Development card's pitch with the picked agent's name.
    var developmentPitch: String?
    let toggle: (OnboardingGoal) -> Void

    private func pitch(_ goal: OnboardingGoal) -> String {
        goal == .development ? (developmentPitch ?? goal.pitch) : goal.pitch
    }

    var body: some View {
        let column = GridItem(.flexible(), spacing: Spacing.medium)
        return LazyVGrid(columns: [column, column], spacing: Spacing.medium) {
            ForEach(OnboardingGoal.allCases, id: \.self) { goal in
                goalCard(goal)
            }
        }
    }

    private func goalCard(_ goal: OnboardingGoal) -> some View {
        let checked = goals.contains(goal)
        return Button {
            toggle(goal)
        } label: {
            HStack(alignment: .top, spacing: Spacing.medium) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(goal.title).fontWeight(.semibold)
                    Text(pitch(goal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.medium + Spacing.tight)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .card(selected: checked, fill: checked ? Fill.selected : Fill.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// The step's bottom row: why Continue waits (or the save error above it)
/// and the one prominent button.
struct OnboardingGoalsFooter: View {
    let hint: String?
    let error: String?
    let canContinue: Bool
    let isContinuing: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.regular) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center) {
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onContinue) {
                    if isContinuing {
                        ProgressView().controlSize(.small).frame(minWidth: 120)
                    } else {
                        Text("Continue").fontWeight(.semibold).frame(minWidth: 120)
                    }
                }
                .onboardingPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue || isContinuing)
            }
        }
    }
}
