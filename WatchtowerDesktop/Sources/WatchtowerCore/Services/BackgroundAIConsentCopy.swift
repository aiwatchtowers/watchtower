import Foundation

/// Every Desktop string of the background AI consent (#1886, spec §5.1 and
/// §6.1–§6.4 of `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md`),
/// plus the phone lines of §6.5 the Mac's design shots draw (the phone's own
/// copy lives in WatchtowerKit). Pinned by `BackgroundAIConsentCopyTests`.
package enum BackgroundAIConsentCopy {
    /// The agent the consent screen names: the configured `ai.provider`.
    package enum Agent: Equatable, Sendable {
        case claude, codex
        /// Any other provider (Ollama, an OpenAI-compatible server), by its
        /// display name.
        case other(name: String)

        /// The agent of provider id `provider` (`ai.provider`); any other
        /// provider by `displayName`.
        package init(provider: String, displayName: String) {
            switch provider {
            case "claude": self = .claude
            case "codex": self = .codex
            default: self = .other(name: displayName)
            }
        }

        package var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .other(let name): name
            }
        }

        /// The plan the runs draw on, for the Settings caption; nil for a
        /// provider with no subscription.
        package var planName: String? {
            switch self {
            case .claude: "your Claude subscription"
            case .codex: "your ChatGPT plan"
            case .other: nil
            }
        }
    }

    // MARK: The consent screen (onboarding step and upgrade sheet)

    package static let stepTitle = "Background AI"
    package static let title = "Let Watchtower run AI in the background?"

    package static func intro(_ agent: Agent) -> String {
        "Watchtower uses \(agent.name) on this Mac to write your digests, briefings, tracks and people cards, "
            + "and to run your automations. Most of this starts on its own, on a schedule or after each sync, "
            + "without you asking each time."
    }

    package static func plan(_ agent: Agent) -> String {
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
    package static func reserve(from preferred: Agent, to reserve: Agent) -> String {
        let plan = reserve == .codex ? "your ChatGPT plan" : "your Claude subscription"
        let limit = preferred == .claude ? "Claude's" : "Codex's"
        return "When \(limit) usage limit is reached, runs switch to \(reserve.name) and use \(plan)."
    }

    package static let whatRunsTitle = "What can run on its own"

    package static func whatRuns(pollMinutes: Int, backfillDays: Int) -> [String] {
        [
            "After each sync, about every \(pollMinutes) min: channel digests, tracks, memory, next steps, "
                + "image and link descriptions",
            "Every few hours: ideas, Jira and mail digests",
            "Once a day: the morning briefing, day plan and people cards. Once a week: agent coaching",
            "After you connect a source: its last \(backfillDays) days of history, a little at each sync",
            "Your automations that use AI, at the times and on the events you set"
        ]
    }

    package static let userStarted = "Chats, Catch-Up, Run now and anything else you start yourself always run, "
        + "whatever you pick here."
    package static let notNowNote = "Not now: Slack, mail, calendar and Jira keep syncing. AI features and "
        + "automations wait until you allow them."
    package static let changeLater = "You can change this any time in Settings → System → AI → Background AI."
    package static let allow = "Allow background AI"
    package static let notNow = "Not now"
    package static let back = "Back"
    package static let saving = "Saving your choice…"
    /// The answer is saved but what follows it (onboarding's finish) failed:
    /// only that runs again. Also the step's re-read of an unreadable
    /// config.yaml.
    package static let finishRetry = "Try again"

    package static func saveFailed(_ error: String) -> String {
        "Couldn't save your choice: \(error). Nothing runs in the background until it is saved."
    }

    /// Settings' switch turned off and the pause was not written: background
    /// AI is still on (the stored answer stands).
    package static func pauseFailed(_ error: String) -> String {
        "Couldn't pause background AI: \(error). It is still on."
    }

    /// Instead of the consent sheet while config.yaml cannot be read: the
    /// answer's writer refuses a file it cannot parse.
    package static let configUnreadableTitle = "Watchtower can't read config.yaml"
    package static let configUnreadable = "Your background AI choice can't be saved until the file is fixed."

    // MARK: Settings → System → AI → Background AI

    package static let sectionTitle = "Background AI"
    package static let switchTitle = "Run AI in the background"

    package static func captionAllowed(_ agent: Agent) -> String {
        let using = agent.planName.map { ", using \($0)" } ?? ""
        return "On. Digests, briefings, tracks, people cards, memory and your automations run on their own\(using)."
    }

    package static let captionPaused = "Paused. Slack, mail, calendar and Jira keep syncing; AI features and "
        + "automations wait."
    package static let captionOrgOff = "Your organization turned background AI off. Chats and anything you start "
        + "yourself still work."
    package static let captionOrgAllowed = "Allowed by your organization. Turn it off to pause it for yourself."
    package static let settingsFooter = "Turning it on shows what runs and asks you to confirm. Turning it off "
        + "pauses at once; a model call already running finishes."

    // MARK: Readiness, Home and Automations

    package static let readinessPaused = "Paused — background AI is off"
    package static let readinessOrg = "Off — your organization turned background AI off"
    package static let allowAction = "Allow background AI…"

    package static let homeTitle = "Background AI is paused"
    package static let homeBody = "Digests, briefings, tracks, people cards, memory and automations wait. "
        + "Slack, mail, calendar and Jira keep syncing."
    package static let homeOrgTitle = "Background AI is off"
    package static let homeOrgBody = "Your organization turned it off. Chats, Catch-Up and anything you start "
        + "yourself still work."

    package static let automationsNotice = "Background AI is paused: scheduled and event automations that use AI "
        + "wait. Run now still works."

    package static let automationsOrgNotice = "Your organization turned background AI off: scheduled and event "
        + "automations that use AI don't run. Run now still works."
    /// The run-state chip of an automation held by the pause.
    package static let automationWaitingChip = "Waiting"

    // MARK: Phone (Home, from the heartbeat's `background_ai`)

    package static let phonePaused = "Digests and briefings aren't updating: background AI is paused on your Mac. "
        + "Allow it in Watchtower on the Mac."
    package static let phoneOrg = "Digests and briefings aren't updating: your organization turned background AI off."
}
