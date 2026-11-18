import XCTest
@testable import WatchtowerCore

/// Pins the background AI consent strings (spec §5.1, §6.1–§6.5 of
/// `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md`) so
/// the screens, the mockups and the spec cannot drift apart.
final class BackgroundAIConsentCopyTests: XCTestCase {
    private typealias Copy = BackgroundAIConsentCopy

    /// The screen names the agent and the owner's own plan and limits.
    func testConsentNamesTheAgentAndTheOwnersPlan() {
        XCTAssertTrue(Copy.intro(.claude).contains("Claude Code on this Mac"))
        XCTAssertTrue(Copy.intro(.codex).contains("Codex on this Mac"))
        XCTAssertTrue(Copy.intro(.other(name: "Ollama")).hasPrefix("Watchtower uses Ollama on this Mac"))
        XCTAssertEqual(
            Copy.plan(.claude),
            "These runs use your own Claude subscription and count toward its usage limits, the same as when "
                + "you use Claude Code yourself. Watchtower never pays for, sees or shares your sign-in."
        )
        XCTAssertEqual(
            Copy.plan(.codex),
            "These runs use your own ChatGPT plan and count toward its Codex usage limits, the same as when "
                + "you use Codex yourself. Watchtower never pays for, sees or shares your sign-in."
        )
        XCTAssertEqual(
            Copy.plan(.other(name: "Ollama")),
            "These runs use Ollama, the model server set in Settings → AI."
        )
    }

    /// The reserve line, both directions.
    func testReserveLineBothDirections() {
        XCTAssertEqual(
            Copy.reserve(from: .claude, to: .codex),
            "When Claude's usage limit is reached, runs switch to Codex and use your ChatGPT plan."
        )
        XCTAssertEqual(
            Copy.reserve(from: .codex, to: .claude),
            "When Codex's usage limit is reached, runs switch to Claude Code and use your Claude subscription."
        )
    }

    /// What runs and how often, from the poll interval and backfill days.
    func testWhatRunsUsesTheConfiguredIntervals() {
        XCTAssertEqual(Copy.whatRuns(pollMinutes: 15, backfillDays: 30), [
            "After each sync, about every 15 min: channel digests, tracks, memory, next steps, "
                + "image and link descriptions",
            "Every few hours: ideas, Jira and mail digests",
            "Once a day: the morning briefing, day plan and people cards. Once a week: agent coaching",
            "After you connect a source: its last 30 days of history, a little at each sync",
            "Your automations that use AI, at the times and on the events you set"
        ])
    }

    /// The owner can always say no and change it later; started work never waits.
    func testTheScreenSaysHowToTurnItOff() {
        XCTAssertEqual(Copy.title, "Let Watchtower run AI in the background?")
        XCTAssertEqual(Copy.allow, "Allow background AI")
        XCTAssertEqual(Copy.notNow, "Not now")
        XCTAssertEqual(Copy.back, "Back")
        XCTAssertEqual(Copy.saving, "Saving your choice…")
        XCTAssertEqual(Copy.changeLater, "You can change this any time in Settings → AI → Background AI.")
        XCTAssertEqual(
            Copy.userStarted,
            "Chats, Catch-Up, Run now and anything else you start yourself always run, whatever you pick here."
        )
        XCTAssertEqual(
            Copy.notNowNote,
            "Not now: Slack, mail, calendar and Jira keep syncing. AI features and automations wait until you allow them."
        )
        XCTAssertTrue(Copy.saveFailed("x").hasSuffix("Nothing runs in the background until it is saved."))
        XCTAssertEqual(Copy.pauseFailed("disk full"), "Couldn't pause background AI: disk full. It is still on.")
    }

    /// The Settings caption per agent: no "using …" for a provider without a plan.
    func testSettingsCaptionsPerAgent() {
        let lead = "On. Digests, briefings, tracks, people cards, memory and your automations run on their own"
        XCTAssertEqual(Copy.captionAllowed(.claude), lead + ", using your Claude subscription.")
        XCTAssertEqual(Copy.captionAllowed(.codex), lead + ", using your ChatGPT plan.")
        XCTAssertEqual(Copy.captionAllowed(.other(name: "Ollama")), lead + ".")
        XCTAssertEqual(
            Copy.captionPaused,
            "Paused. Slack, mail, calendar and Jira keep syncing; AI features and automations wait."
        )
        XCTAssertEqual(
            Copy.captionOrgOff,
            "Your organization turned background AI off. Chats and anything you start yourself still work."
        )
        XCTAssertEqual(Copy.captionOrgAllowed, "Allowed by your organization. Turn it off to pause it for yourself.")
    }

    func testReadinessHomeAndAutomationsCopy() {
        XCTAssertEqual(Copy.readinessPaused, "Paused — background AI is off")
        XCTAssertEqual(Copy.readinessOrg, "Off — your organization turned background AI off")
        XCTAssertEqual(Copy.allowAction, "Allow background AI…")
        XCTAssertEqual(Copy.homeTitle, "Background AI is paused")
        XCTAssertEqual(Copy.homeOrgTitle, "Background AI is off")
        XCTAssertEqual(
            Copy.automationsNotice,
            "Background AI is paused: scheduled and event automations that use AI wait. Run now still works."
        )
        XCTAssertTrue(Copy.automationsOrgNotice.hasSuffix("Run now still works."))
        XCTAssertEqual(Copy.automationWaitingChip, "Waiting")
    }

    /// The phone explains the stale feed and points to the Mac.
    func testPhoneLines() {
        XCTAssertTrue(Copy.phonePaused.hasSuffix("Allow it in Watchtower on the Mac."))
        XCTAssertTrue(Copy.phoneOrg.contains("your organization"))
    }

    /// Instead of the sheet while config.yaml cannot be read.
    func testConfigUnreadableExplainsWhyNothingCanBeSaved() {
        XCTAssertEqual(Copy.configUnreadableTitle, "Watchtower can't read config.yaml")
        XCTAssertEqual(Copy.configUnreadable, "Your background AI choice can't be saved until the file is fixed.")
        XCTAssertEqual(Copy.finishRetry, "Try again")
    }
}
