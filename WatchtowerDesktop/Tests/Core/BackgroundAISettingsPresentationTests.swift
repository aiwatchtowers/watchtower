import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Settings → System → AI → Background AI (#1886, spec §6.1): one row per state of
/// the table, the switch and its caption.
final class BackgroundAISettingsPresentationTests: XCTestCase {
    private typealias Copy = BackgroundAIConsentCopy
    private typealias Presentation = BackgroundAISettingsPresentation

    private func state(_ answer: String?, policy: Bool? = nil) -> BackgroundAIConsent.State { // swiftlint:disable:this discouraged_optional_boolean
        BackgroundAIConsent.resolve(answer: answer, policy: policy)
    }

    func testAllowedClaude() {
        let shown = Presentation.make(state: state("allowed"), agent: .claude, isSaving: false, error: nil, configUnreadable: false)
        XCTAssertEqual(shown, Presentation(isOn: true, locked: false, caption: Copy.captionAllowed(.claude), captionIsError: false))
        XCTAssertEqual(
            shown.caption,
            "On. Digests, briefings, tracks, people cards, memory and your automations run on their own, "
                + "using your Claude subscription."
        )
        let codex = Presentation.make(state: state("allowed"), agent: .codex, isSaving: false, error: nil, configUnreadable: false)
        XCTAssertTrue(codex.caption.hasSuffix(", using your ChatGPT plan."))
    }

    func testAllowedOllamaHasNoPlanClause() {
        let shown = Presentation.make(state: state("allowed"), agent: .other(name: "Ollama"), isSaving: false, error: nil, configUnreadable: false)
        XCTAssertTrue(shown.isOn)
        XCTAssertEqual(
            shown.caption,
            "On. Digests, briefings, tracks, people cards, memory and your automations run on their own."
        )
    }

    func testPausedOwnerAndUnanswered() {
        for answer in ["paused", nil] {
            let shown = Presentation.make(state: state(answer), agent: .claude, isSaving: false, error: nil, configUnreadable: false)
            XCTAssertEqual(shown, Presentation(isOn: false, locked: false, caption: Copy.captionPaused, captionIsError: false))
        }
        XCTAssertEqual(
            Copy.captionPaused,
            "Paused. Slack, mail, calendar and Jira keep syncing; AI features and automations wait."
        )
        // The owner's own pause wins over a permissive profile.
        let ownerOverOrg = Presentation.make(
            state: state("paused", policy: true), agent: .claude, isSaving: false, error: nil, configUnreadable: false
        )
        XCTAssertFalse(ownerOverOrg.isOn)
        XCTAssertFalse(ownerOverOrg.locked)
    }

    func testOrgOffLocked() {
        for answer in ["allowed", "paused", nil] {
            let shown = Presentation.make(state: state(answer, policy: false), agent: .claude, isSaving: false, error: nil, configUnreadable: false)
            XCTAssertEqual(shown, Presentation(isOn: false, locked: true, caption: Copy.captionOrgOff, captionIsError: false))
        }
        XCTAssertEqual(
            Copy.captionOrgOff,
            "Your organization turned background AI off. Chats and anything you start yourself still work."
        )
    }

    func testOrgAllowedCaption() {
        let shown = Presentation.make(state: state(nil, policy: true), agent: .claude, isSaving: false, error: nil, configUnreadable: false)
        XCTAssertEqual(shown, Presentation(isOn: true, locked: false, caption: Copy.captionOrgAllowed, captionIsError: false))
        XCTAssertEqual(Copy.captionOrgAllowed, "Allowed by your organization. Turn it off to pause it for yourself.")
        // The owner's own yes under a permissive profile is the owner's.
        let owner = Presentation.make(state: state("allowed", policy: true), agent: .claude, isSaving: false, error: nil, configUnreadable: false)
        XCTAssertEqual(owner.caption, Copy.captionAllowed(.claude))
    }

    /// A call in flight leaves the caption and the switch as stored, and
    /// hides a previous error.
    func testSavingKeepsCaption() {
        for answer in ["allowed", "paused"] {
            let idle = Presentation.make(state: state(answer), agent: .claude, isSaving: false, error: nil, configUnreadable: false)
            let saving = Presentation.make(state: state(answer), agent: .claude, isSaving: true, error: "stale", configUnreadable: false)
            XCTAssertEqual(saving, idle)
        }
    }

    func testErrorFallsBackToStored() {
        let line = Copy.saveFailed("config.yaml: permission denied")
        for (answer, on) in [("allowed", true), ("paused", false)] {
            let shown = Presentation.make(state: state(answer), agent: .claude, isSaving: false, error: line, configUnreadable: false)
            XCTAssertEqual(shown, Presentation(isOn: on, locked: false, caption: line, captionIsError: true))
        }
    }

    /// config.yaml that cannot be read: the switch reads paused and the
    /// caption says why the choice cannot be saved.
    func testUnreadableConfigSaysWhy() {
        let unreadable = BackgroundAIConsent.resolve(answer: nil, readFailed: true, policy: nil)
        let shown = Presentation.make(state: unreadable, agent: .claude, isSaving: false, error: nil, configUnreadable: true)
        XCTAssertFalse(shown.isOn)
        XCTAssertTrue(shown.captionIsError)
        XCTAssertEqual(
            shown.caption,
            "Watchtower can't read config.yaml. Your background AI choice can't be saved until the file is fixed."
        )
        // The organization's lock still speaks first.
        let locked = BackgroundAIConsent.resolve(answer: nil, readFailed: true, policy: false)
        let org = Presentation.make(state: locked, agent: .claude, isSaving: false, error: nil, configUnreadable: true)
        XCTAssertEqual(org, Presentation(isOn: false, locked: true, caption: Copy.captionOrgOff, captionIsError: false))
    }
}
