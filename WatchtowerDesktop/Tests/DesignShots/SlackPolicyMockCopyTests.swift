import XCTest

/// Pins the Slack Developer Policy hygiene spec's string table
/// (`docs/superpowers/specs/2026-11-17-slack-policy-hygiene-design.md`, §8)
/// so the mockups and the spec text cannot drift. The implementation moves
/// these strings into the models the spec names and pins them there.
@MainActor
final class SlackPolicyMockCopyTests: XCTestCase {
    typealias Copy = SlackPolicyMockCopy

    func testPrivacyFootnotesTellTheTruthInEveryState() {
        XCTAssertTrue(Copy.footOnAll.contains("72 hours"))
        XCTAssertTrue(Copy.footOnAll.contains("has not reached its source for 30 days"))
        XCTAssertTrue(Copy.footOnAll.hasSuffix("meeting transcripts are kept."))
        XCTAssertTrue(Copy.footOff.contains("Reset All Data…"))
        XCTAssertTrue(Copy.footOff.contains("14 business days"))
        XCTAssertEqual(Copy.captionDefault, "Off by default")
    }

    func testRemoveDialogSaysTheSignOutReachesEveryMac() {
        for body in [Copy.removeBodyOn, Copy.removeBodyOff] {
            XCTAssertTrue(body.contains("signs out of it at Slack"))
            XCTAssertTrue(body.contains("every Mac"))
        }
        XCTAssertTrue(Copy.removeBodyOn.contains("deleted in 72 hours"))
        XCTAssertFalse(Copy.removeBodyOff.contains("72 hours"))
    }

    func testDisclosureNamesEveryProviderAndTraining() {
        let text = Copy.disclosureLines.joined(separator: " ")
        for name in ["Anthropic (Claude)", "OpenAI (Codex)", "Ollama", "never trains", "can be wrong"] {
            XCTAssertTrue(text.contains(name), name)
        }
        XCTAssertTrue(Copy.connectLine.contains("AI provider"))
    }

    func testPeopleCopyHoldsNoActivityScoresOrJudgments() {
        XCTAssertEqual(Copy.stopCard, "Stop card for this person")
        XCTAssertTrue(Copy.stopBody.contains("Find experts are not affected"))
        XCTAssertEqual(Copy.makeAgain, "Make cards again")
        XCTAssertTrue(Copy.basisLine.hasPrefix("Based on"))
        let shown = ([Copy.personSummary, Copy.guideText, Copy.teamSummary] + Copy.tactics + Copy.tips
            + Copy.peopleRows.map(\.line)).joined(separator: " ").lowercased()
        for banned in ["red flag", "burnout", "active hours", "attention", "%"] {
            XCTAssertFalse(shown.contains(banned), banned)
        }
    }

    func testEveryFrameHasAShot() {
        let names = Set(SlackPolicyShotFixtures.shots.map(\.name))
        for frame in SlackPolicyShotFixtures.Frame.allCases {
            XCTAssertTrue(names.contains("slack-ph-\(frame.rawValue)"), frame.rawValue)
        }
    }
}
