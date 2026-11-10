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
        var other = OnboardingAgentChoice(statuses: [.claude: .ready, .codex: .notInstalled], otherProvider: "Ollama")
        other.applyDefault(configured: "ollama")
        var otherFailed = OnboardingAgentChoice(
            statuses: [.claude: .ready, .codex: .notInstalled],
            otherProvider: "Ollama",
            otherProviderFailure: "Couldn’t reach the server at http://localhost:11434."
        )
        otherFailed.applyDefault(configured: "ollama")
        var signingIn = choice(.signedOut, .notInstalled)
        signingIn.signInStarted()
        var signInStopped = signingIn
        signInStopped.signInStopped()
        return [
            Scene(name: "checking", choice: OnboardingAgentChoice()),
            Scene(name: "both-ready", choice: bothReady),
            Scene(name: "both-ready-codex", choice: choice(.ready, .ready, pick: .codex)),
            Scene(name: "only-codex", choice: choice(.notInstalled, .ready)),
            Scene(name: "signed-out", choice: signingIn),
            Scene(name: "signed-out-stopped", choice: signInStopped),
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
                    signInTerminal: { AnyView(TerminalStill(command: scene.choice.selected?.signInCommand ?? "")) }
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
                Text("Opening your browser to sign in…")
                Text("If it didn’t open, visit: https://example.com/oauth/authorize?code=…")
                Text("Waiting for the browser… ▍")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(Spacing.cozy)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Fill.card)
        }
    }
}
