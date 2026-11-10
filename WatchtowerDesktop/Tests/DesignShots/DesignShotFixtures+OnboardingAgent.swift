import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Goals step with the AI agent section (#1521), one shot per state of
/// `OnboardingAgentChoice`. Built from the step's own parts: goal cards,
/// language row, agent section, footer.
@MainActor
enum OnboardingAgentShotFixtures {
    private struct Scene {
        var name: String
        var choice: OnboardingAgentChoice
        var continuing = false
        var error: String?
        var narrow = false
    }

    static var shots: [DesignShot] {
        scenes.map { scene in
            DesignShot(name: "onboarding-agent-\(scene.name)", size: NSSize(width: scene.narrow ? 600 : 860, height: 0)) {
                AnyView(StepView(scene: scene))
            }
        }
    }

    private static func choice(
        _ claude: OnboardingAgentChoice.Status,
        _ codex: OnboardingAgentChoice.Status,
        configured: String? = nil,
        pick: OnboardingAgentChoice.Agent? = nil
    ) -> OnboardingAgentChoice {
        var choice = OnboardingAgentChoice(statuses: [.claude: claude, .codex: codex])
        choice.applyDefault(configured: configured)
        if let pick { choice.pick(pick) }
        return choice
    }

    private static var scenes: [Scene] {
        let bothReady = choice(.ready, .ready)
        var other = OnboardingAgentChoice(statuses: [.claude: .ready, .codex: .notInstalled], otherProvider: OnboardingAgentChoice.providerName("ollama"))
        other.applyDefault(configured: "ollama")
        var otherFailed = OnboardingAgentChoice(
            statuses: [.claude: .ready, .codex: .notInstalled],
            otherProvider: OnboardingAgentChoice.providerName("ollama"),
            otherProviderFailure: OnboardingAgentChoice.otherFailureLine(code: "transport", error: nil)
        )
        otherFailed.applyDefault(configured: "ollama")
        var signingIn = choice(.signedOut, .notInstalled)
        signingIn.signInStarted()
        var updating = choice(.signedOut, .notInstalled)
        updating.installs = [.claude: .init(path: "/Users/acme/.local/share/claude/versions/1.0.88", kind: .native)]
        updating.applyLoginProbe(outdated: [.claude])
        updating.signInStarted()
        var updateFailed = updating
        updateFailed.signInEnded(exitCode: 1)
        var stuck = updating
        stuck.signInEnded(exitCode: 0)
        stuck.applyLoginProbe(outdated: [.claude])
        var signInStopped = signingIn
        signInStopped.signInStopped()
        return [
            Scene(name: "checking", choice: OnboardingAgentChoice()),
            Scene(name: "both-ready", choice: bothReady),
            Scene(name: "both-ready-codex", choice: choice(.ready, .ready, pick: .codex)),
            Scene(name: "only-codex", choice: choice(.notInstalled, .ready)),
            Scene(name: "signed-out", choice: signingIn),
            Scene(name: "signed-out-stopped", choice: signInStopped),
            Scene(name: "signed-out-outdated", choice: updating),
            Scene(name: "signed-out-update-failed", choice: updateFailed),
            Scene(name: "signed-out-update-stuck", choice: stuck),
            Scene(name: "none", choice: choice(.notInstalled, .notInstalled)),
            Scene(name: "none-codex", choice: choice(.notInstalled, .notInstalled, pick: .codex)),
            Scene(name: "failed", choice: choice(
                .failed(OnboardingAgentChoice.failureMessage(.claude, code: "timeout", error: nil)),
                .notInstalled
            )),
            Scene(name: "policy", choice: choice(.forbidden, .ready)),
            Scene(name: "policy-both", choice: choice(.forbidden, .forbidden)),
            Scene(name: "other-provider", choice: other),
            Scene(name: "other-provider-failed", choice: otherFailed),
            Scene(name: "continuing", choice: bothReady, continuing: true),
            Scene(name: "save-error", choice: bothReady,
                  error: OnboardingAgentChoice.saveFailure + " config set ai.provider: permission denied"),
            Scene(name: "none-narrow", choice: choice(.notInstalled, .notInstalled), narrow: true)
        ]
    }

    private struct StepView: View {
        let scene: Scene

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text("What do you want Watchtower for?").font(.headline)
                    Text("Pick any").font(.subheadline).foregroundStyle(.secondary)
                }
                OnboardingGoalCards(
                    goals: Set(OnboardingGoal.allCases),
                    developmentPitch: scene.choice.developmentPitch
                ) { _ in }
                AssistantLanguageRow(selection: .constant("English"))
                OnboardingAgentSection(
                    choice: scene.choice, onPick: { _ in }, onCheckAgain: {}, onChoosePath: { _ in },
                    signInTerminal: { AnyView(TerminalStill(command: scene.choice.terminalCommand ?? "")) }
                )
                OnboardingGoalsFooter(
                    hint: scene.choice.continueHint,
                    error: scene.error,
                    canContinue: scene.choice.canContinue,
                    isContinuing: scene.continuing,
                    onContinue: {}
                )
                .padding(.top, Spacing.regular)
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Surface.window)
        }
    }

    /// A still of the sign-in terminal: what `claude auth login` prints
    /// while it waits for the browser. Sample text only.
    private struct TerminalStill: View {
        let command: String

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("$ \(command)")
                if command.hasSuffix("update") {
                    Text("Current version: 1.0.88")
                    Text("Checking for updates… ▍")
                } else {
                    Text("Opening your browser to sign in…")
                    Text("If it didn’t open, visit: https://example.com/oauth/authorize?code=…")
                    Text("Waiting for the browser… ▍")
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(Spacing.cozy)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Fill.card)
        }
    }
}

/// The same scenes from the real `OnboardingGoalsStepView` (#1521 Task 5),
/// with the model brought to each state through its own API and a fake
/// check, to compare with the mockups above. Not the four scenes that need
/// a live PTY or a held Continue (`signed-out`, `signed-out-outdated`,
/// `signed-out-update-failed`, `continuing`): those are checked by hand.
@MainActor
enum OnboardingStepLiveShotFixtures {
    private typealias Choice = OnboardingAgentChoice

    private struct Scene {
        var name: String
        var result: OnboardingAgentCheckResult
        var configured: String?
        var narrow = false
        /// The check never answers (the checking scene).
        var hangs = false
        var saveError: String?
        /// What the owner did after the check.
        var after: @MainActor (OnboardingGoalsModel) async -> Void = { _ in }
    }

    private struct SaveError: LocalizedError {
        let errorDescription: String?
    }

    static var shots: [DesignShot] {
        scenes.map { scene in
            DesignShot(name: "onboarding-step-live-\(scene.name)", size: NSSize(width: scene.narrow ? 600 : 860, height: 0)) {
                let model = seeded(scene)
                let appState = AppState(
                    onboardingDefaults: AppState.isolatedDefaults,
                    workbenchDefaults: AppState.isolatedDefaults,
                    onboardingGoals: model
                )
                return AnyView(
                    OnboardingGoalsStepView { _ in }
                        .padding(Spacing.page)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Surface.window)
                        .environment(appState)
                )
            }
        }
    }

    private static func result(
        _ claude: Choice.Status,
        _ codex: Choice.Status,
        installs: [Choice.Agent: Choice.Install] = [:],
        outdated: Set<Choice.Agent> = [],
        other: String? = nil,
        otherFailure: String? = nil
    ) -> OnboardingAgentCheckResult {
        OnboardingAgentCheckResult(
            statuses: [.claude: claude, .codex: codex], installs: installs, outdated: outdated,
            otherProvider: other, otherProviderFailure: otherFailure
        )
    }

    private static var scenes: [Scene] {
        let bothReady = result(.ready, .ready)
        let none = result(.notInstalled, .notInstalled)
        let ollama = Choice.providerName("ollama")
        let oldClaude = Choice.Install(path: "/Users/acme/.local/share/claude/versions/1.0.88", kind: .native)
        return [
            Scene(name: "checking", result: bothReady, hangs: true),
            Scene(name: "both-ready", result: bothReady),
            Scene(name: "both-ready-codex", result: bothReady) { $0.pickAgent(.codex) },
            Scene(name: "only-codex", result: result(.notInstalled, .ready)),
            Scene(name: "signed-out-stopped", result: result(.signedOut, .notInstalled)) {
                $0.signInStarted()
                $0.signInStopped()
            },
            Scene(
                name: "signed-out-update-stuck",
                result: result(.signedOut, .notInstalled, installs: [.claude: oldClaude], outdated: [.claude])
            ) {
                $0.signInStarted()
                await $0.signInEnded(exitCode: 0)
            },
            Scene(name: "none", result: none),
            Scene(name: "none-codex", result: none) { $0.pickAgent(.codex) },
            Scene(name: "none-narrow", result: none, narrow: true),
            Scene(name: "failed", result: result(
                .failed(Choice.failureMessage(.claude, code: "timeout", error: nil)), .notInstalled
            )),
            Scene(name: "policy", result: result(.forbidden, .ready)),
            Scene(name: "policy-both", result: result(.forbidden, .forbidden)),
            Scene(name: "other-provider", result: result(.ready, .notInstalled, other: ollama), configured: "ollama"),
            Scene(
                name: "other-provider-failed",
                result: result(.ready, .notInstalled, other: ollama,
                               otherFailure: Choice.otherFailureLine(code: "transport", error: nil)),
                configured: "ollama"
            ),
            Scene(name: "save-error", result: bothReady,
                  saveError: "config set ai.provider: permission denied") { model in
                _ = await model.submit(hasSlackAccount: true)
            }
        ]
    }

    /// A model in the scene's state: the language prepared (the step's own
    /// `.task` then reads no config value into it) and the check answered,
    /// the run loop turned until that is done.
    private static func seeded(_ scene: Scene) -> OnboardingGoalsModel {
        let check = scene.result
        let hangs = scene.hangs
        let saveError = scene.saveError
        let model = OnboardingGoalsModel(
            defaults: AppState.isolatedDefaults,
            systemLanguage: "English",
            checkAgents: {
                if hangs { try? await Task.sleep(for: .seconds(3600)) }
                return check
            },
            configuredProvider: { scene.configured },
            actions: OnboardingGoalsActions(
                initWorkspace: {},
                setLanguage: { _ in },
                applyFeatures: { _ in (nil, false) },
                saveAgent: { _ in
                    if let saveError { throw SaveError(errorDescription: saveError) }
                }
            )
        )
        let done = Flag()
        Task { @MainActor in
            if hangs {
                Task { await model.prepareGoalsStep(configuredLanguage: "English") }
                await Task.yield()
            } else {
                await model.prepareGoalsStep(configuredLanguage: "English")
                await scene.after(model)
            }
            done.value = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done.value, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return model
    }

    @MainActor
    private final class Flag {
        var value = false
    }
}
