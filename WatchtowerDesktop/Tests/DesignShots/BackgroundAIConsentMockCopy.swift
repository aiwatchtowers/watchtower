import Foundation

/// Design-only string table of the background AI consent spec
/// (`docs/superpowers/specs/2026-11-17-background-ai-consent-design.md`,
/// target #1886). The implementation moves each group into the model the
/// spec names (`BackgroundAIConsentCopy` in WatchtowerCore,
/// `FeatureReadiness.line`, `GettingReadyPolicy`) and pins it there;
/// `BackgroundAIConsentMockCopyTests` pins this table so the mockups and
/// the spec cannot drift apart.
enum BackgroundAIConsentMockCopy {
    /// The agent the consent screen names: the configured `ai.provider`.
    enum Agent: Equatable {
        case claude, codex
        /// Any other provider (Ollama, an OpenAI-compatible server), by its
        /// display name.
        case other(String)

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .other(let name): name
            }
        }

        /// The plan the runs draw on, for the Settings caption; nil for a
        /// provider with no subscription.
        var planName: String? {
            switch self {
            case .claude: "your Claude subscription"
            case .codex: "your ChatGPT plan"
            case .other: nil
            }
        }
    }

    // MARK: The consent screen (onboarding step and upgrade sheet)

    static let stepTitle = "Background AI"
    static let title = "Let Watchtower run AI in the background?"

    static func intro(_ agent: Agent) -> String {
        "Watchtower uses \(agent.name) on this Mac to write your digests, briefings, tracks and people cards, "
            + "and to run your automations. Most of this starts on its own, on a schedule or after each sync, "
            + "without you asking each time."
    }

    static func plan(_ agent: Agent) -> String {
        switch agent {
        case .claude:
            "These runs use your own Claude subscription and count toward its usage limits, the same as when "
                + "you use Claude Code yourself. Watchtower never pays for, sees or shares your sign-in."
        case .codex:
            "These runs use your own ChatGPT plan and count toward its Codex usage limits, the same as when "
                + "you use Codex yourself. Watchtower never pays for, sees or shares your sign-in."
        case .other(let name):
            "These runs use \(name), the model server set in Settings → AI."
        }
    }

    /// Shown only while the automatic reserve is on (Settings → AI).
    static func reserve(from preferred: Agent, to reserve: Agent) -> String {
        let plan = reserve == .codex ? "your ChatGPT plan" : "your Claude subscription"
        let limit = preferred == .claude ? "Claude's" : "Codex's"
        return "When \(limit) usage limit is reached, runs switch to \(reserve.name) and use \(plan)."
    }

    static let whatRunsTitle = "What can run on its own"

    static func whatRuns(pollMinutes: Int, backfillDays: Int) -> [String] {
        [
            "After each sync, about every \(pollMinutes) min: channel digests, tracks, memory, next steps, "
                + "image and link descriptions",
            "Every few hours: ideas, Jira and mail digests",
            "Once a day: the morning briefing, day plan and people cards. Once a week: agent coaching",
            "After you connect a source: its last \(backfillDays) days of history, a little at each sync",
            "Your automations that use AI, at the times and on the events you set"
        ]
    }

    static let userStarted = "Chats, Catch-Up, Run now and anything else you start yourself always run, "
        + "whatever you pick here."
    static let notNowNote = "Not now: Slack, mail, calendar and Jira keep syncing. AI features and "
        + "automations wait until you allow them."
    static let changeLater = "You can change this any time in Settings → AI → Background AI."
    static let allow = "Allow background AI"
    static let notNow = "Not now"
    static let back = "Back"
    static let saving = "Saving your choice…"

    static func saveFailed(_ error: String) -> String {
        "Couldn't save your choice: \(error). Nothing runs in the background until it is saved."
    }

    // MARK: Settings → AI → Background AI

    static let sectionTitle = "Background AI"
    static let switchTitle = "Run AI in the background"

    static func captionAllowed(_ agent: Agent) -> String {
        let using = agent.planName.map { ", using \($0)" } ?? ""
        return "On. Digests, briefings, tracks, people cards, memory and your automations run on their own\(using)."
    }

    static let captionPaused = "Paused. Slack, mail, calendar and Jira keep syncing; AI features and "
        + "automations wait."
    static let captionOrgOff = "Your organization turned background AI off. Chats and anything you start "
        + "yourself still work."
    static let captionOrgAllowed = "Allowed by your organization. Turn it off to pause it for yourself."
    static let settingsFooter = "Turning it on shows what runs and asks you to confirm. Turning it off "
        + "pauses at once; a model call already running finishes."

    // MARK: Readiness, Home and Automations

    static let readinessPaused = "Paused — background AI is off"
    static let readinessOrg = "Off — your organization turned background AI off"
    static let allowAction = "Allow background AI…"

    static let homeTitle = "Background AI is paused"
    static let homeBody = "Digests, briefings, tracks, people cards, memory and automations wait. "
        + "Slack, mail, calendar and Jira keep syncing."
    static let homeOrgTitle = "Background AI is off"
    static let homeOrgBody = "Your organization turned it off. Chats, Catch-Up and anything you start "
        + "yourself still work."

    static let automationsNotice = "Background AI is paused: scheduled and event automations that use AI "
        + "wait. Run now still works."
    // MARK: Phone (Home, from the heartbeat's `background_ai`)

    static let phonePaused = "Digests and briefings aren't updating: background AI is paused on your Mac. "
        + "Allow it in Watchtower on the Mac."
    static let phoneOrg = "Digests and briefings aren't updating: your organization turned background AI off."

    /// The run-state chip of an automation held by the pause.
    static let automationWaitingChip = "Waiting"
    static let automationsOrgNotice = "Your organization turned background AI off: scheduled and event "
        + "automations that use AI don't run. Run now still works."
}
