import WatchtowerCore
@testable import WatchtowerDesktop
import XCTest

/// Pins the Slack Full / Live screens spec's string table
/// (`docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md`)
/// so the fixtures and the spec text cannot drift; where the app has the
/// string (the view models the spec names), it is compared with it here.
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
        XCTAssertTrue(Copy.adoptBody.contains("which can be turned off only by Slack support"))
        XCTAssertTrue(Copy.adoptConfirm.hasSuffix(Copy.adoptPKCEWarning), "the App ID check keeps the PKCE warning")
        XCTAssertEqual(Copy.adoptAction, "Update the app")
        XCTAssertTrue(Copy.notCollaborator.contains("collaborators"))
        XCTAssertTrue(Copy.onboardingCaption.contains("paste the link or code"))
        XCTAssertEqual(Copy.onboardingTitle, "Connect Slack")
    }

    /// Plan B Task 15: the shipped shared-app and onboarding strings are the
    /// mockups' (the shots now draw the real views).
    func testShippedSharedAppAndOnboardingCopy() {
        typealias Copy = SlackFullLiveMockCopy
        let banner = SlackPaneModeFixture.presentation(.sharedApp).sharedAppBanner
        XCTAssertEqual(banner?.title, Copy.sharedTitle)
        XCTAssertEqual(banner?.body, Copy.sharedBody)
        XCTAssertEqual(banner?.setUpForCompany, Copy.setUpForCompany)
        XCTAssertEqual(banner?.pasteLink, Copy.pasteALink)
        XCTAssertEqual(SlackModePresentation.sharedAppTag, Copy.chipShared)
        XCTAssertEqual(SlackModePresentation.sharedAppAccountLine(
            lastSync: SlackPaneModeFixture.now.addingTimeInterval(-180), now: SlackPaneModeFixture.now), Copy.accountShared)
        XCTAssertEqual(SlackConnectFlowModel.onboardingTitle, Copy.onboardingTitle)
        XCTAssertEqual(SlackConnectFlowModel.onboardingCaption, Copy.onboardingCaption)
        XCTAssertEqual(SlackConnectFlowModel.onboardingLiveHint, Copy.onboardingLiveHint)
        XCTAssertEqual(SlackConnectFlowModel.onboardingSkip, Copy.skip)
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
