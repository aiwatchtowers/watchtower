import WatchtowerCore
import XCTest

/// Pins the Slack Full / Live screens spec's string table
/// (`docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md`)
/// so the mockups and the spec text cannot drift. The implementation moves
/// these strings into the view models the spec names and pins them there.
@MainActor
final class SlackFullLiveMockCopyTests: XCTestCase {
    func testModeChipsAndSummaries() {
        typealias Copy = SlackFullLiveMockCopy
        XCTAssertEqual([Copy.chipFull, Copy.chipFullLive, Copy.chipLive, Copy.chipOff, Copy.chipShared],
                       ["Full", "Full · Live on", "Live", "Off", "Shared app"])
        XCTAssertTrue(Copy.summaryLive.contains("need your workspace's app"))
        XCTAssertTrue(Copy.summaryShared.contains("until Slack turns it off"))
        XCTAssertEqual(Copy.checkAgain, "Check again")
    }

    func testFailureCopyNamesTheFixAndNeverPromisesARetryLoop() {
        typealias Copy = SlackFullLiveMockCopy
        XCTAssertTrue(Copy.portBusy.contains("port 18551 is busy"))
        XCTAssertTrue(Copy.badToken.contains("Generate a new one"))
        XCTAssertTrue(Copy.teamMismatch.hasSuffix("Nothing was saved."))
        XCTAssertTrue(Copy.denied.hasSuffix("Nothing was saved."))
        XCTAssertTrue(Copy.tokenNote.contains("never stored"))
        XCTAssertTrue(Copy.progressCaption.contains("never created twice"))
        XCTAssertEqual(Copy.progressSteps.count, 4)
    }

    func testReadinessAndKeepCopy() {
        typealias Copy = SlackFullLiveMockCopy
        XCTAssertEqual(Copy.needsFullLine, "Needs your workspace's Slack app. Live answers in Chats only.")
        XCTAssertEqual(Copy.needsFullAction, "Connect workspace app")
        // Shipped in plan A: the mock must match the app.
        XCTAssertEqual(Copy.keepReason, ArtifactPanelModel.liveSlackReason)
    }

    func testPlanBAdditions() {
        typealias Copy = SlackFullLiveMockCopy
        XCTAssertEqual(Copy.copyAdminNote, "Copy a note for your admin")
        XCTAssertTrue(Copy.adminNote.contains("docs/guide/"))
        XCTAssertTrue(Copy.adoptBody.contains("Nothing changes for colleagues already connected."))
        XCTAssertEqual(Copy.adoptAction, "Update the app")
        XCTAssertTrue(Copy.notCollaborator.contains("collaborators"))
        XCTAssertTrue(Copy.onboardingCaption.contains("paste the link or code"))
        XCTAssertEqual(Copy.onboardingTitle, "Connect Slack")
    }

    func testEveryFrameHasAShot() {
        let names = Set(SlackFullLiveShotFixtures.shots.map(\.name))
        for pane in SlackFullLiveShotFixtures.Pane.allCases {
            XCTAssertTrue(names.contains("slack-fl-pane-\(pane.rawValue)"))
        }
        for frame in SlackFullLiveShotFixtures.Setup.allCases {
            XCTAssertTrue(names.contains("slack-fl-setup-\(frame.rawValue)"))
        }
        for frame in SlackFullLiveShotFixtures.Onboarding.allCases {
            XCTAssertTrue(names.contains("slack-fl-onboarding-\(frame.rawValue)"))
        }
        for frame in SlackFullLiveShotFixtures.Connect.allCases {
            XCTAssertTrue(names.contains("slack-fl-connect-\(frame.rawValue)"))
        }
    }
}
