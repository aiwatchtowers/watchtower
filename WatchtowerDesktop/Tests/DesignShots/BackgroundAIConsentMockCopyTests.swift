import XCTest

/// Pins the background AI consent spec's string table
/// (`docs/superpowers/specs/2026-11-17-background-ai-consent-design.md`)
/// so the mockups and the spec text cannot drift. The implementation moves
/// these strings into `BackgroundAIConsentCopy` and pins them there.
@MainActor
final class BackgroundAIConsentMockCopyTests: XCTestCase {
    private typealias Copy = BackgroundAIConsentMockCopy

    /// The screen names the agent and the owner's own plan and limits.
    func testConsentNamesTheAgentAndTheOwnersPlan() {
        XCTAssertTrue(Copy.intro(.claude).contains("Claude Code on this Mac"))
        XCTAssertTrue(Copy.intro(.codex).contains("Codex on this Mac"))
        XCTAssertTrue(Copy.plan(.claude).contains("your own Claude subscription and count toward its usage limits"))
        XCTAssertTrue(Copy.plan(.codex).contains("your own ChatGPT plan and count toward its Codex usage limits"))
        XCTAssertEqual(Copy.plan(.other("Ollama")), "These runs use Ollama, the model server set in Settings → AI.")
        XCTAssertEqual(
            Copy.reserve(from: .claude, to: .codex),
            "When Claude's usage limit is reached, runs switch to Codex and use your ChatGPT plan."
        )
    }

    /// What runs and how often, from the poll interval and backfill days.
    func testWhatRunsUsesTheConfiguredIntervals() {
        let rows = Copy.whatRuns(pollMinutes: 15, backfillDays: 30)
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows[0].hasPrefix("After each sync, about every 15 min:"))
        XCTAssertTrue(rows[3].contains("last 30 days of history"))
        XCTAssertTrue(rows[4].hasPrefix("Your automations that use AI"))
    }

    /// The owner can always say no and change it later; started work never waits.
    func testTheScreenSaysHowToTurnItOff() {
        XCTAssertEqual(Copy.allow, "Allow background AI")
        XCTAssertEqual(Copy.notNow, "Not now")
        XCTAssertTrue(Copy.changeLater.contains("Settings → AI → Background AI"))
        XCTAssertTrue(Copy.userStarted.contains("always run"))
        XCTAssertTrue(Copy.notNowNote.contains("keep syncing"))
        XCTAssertTrue(Copy.saveFailed("x").hasSuffix("Nothing runs in the background until it is saved."))
    }

    func testSettingsReadinessAndHomeCopy() {
        XCTAssertEqual(Copy.captionAllowed(.claude),
                       "On. Digests, briefings, tracks, people cards, memory and your automations run on their own, "
                           + "using your Claude subscription.")
        XCTAssertFalse(Copy.captionAllowed(.other("Ollama")).contains("using"))
        XCTAssertEqual(Copy.readinessPaused, "Paused — background AI is off")
        XCTAssertEqual(Copy.readinessOrg, "Off — your organization turned background AI off")
        XCTAssertEqual(Copy.allowAction, "Allow background AI…")
        XCTAssertTrue(Copy.automationsNotice.hasSuffix("Run now still works."))
    }

    /// The phone explains the stale feed and points to the Mac.
    func testPhoneLines() {
        XCTAssertTrue(Copy.phonePaused.hasSuffix("Allow it in Watchtower on the Mac."))
        XCTAssertTrue(Copy.phoneOrg.contains("your organization"))
    }

    func testEveryFrameHasAShot() {
        let names = Set(BackgroundAIConsentShotFixtures.shots.map(\.name))
        for step in BackgroundAIConsentShotFixtures.Step.allCases {
            XCTAssertTrue(names.contains("ai-consent-step-\(step.rawValue)"))
        }
        for state in BackgroundAIConsentShotFixtures.Settings.allCases {
            XCTAssertTrue(names.contains("ai-consent-settings-\(state.rawValue)"))
        }
    }
}
