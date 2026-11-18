import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Pins the company setup screens spec's string table
/// (`docs/superpowers/specs/2026-11-18-company-setup-screens-design.md`) so
/// the mockups and the spec text cannot drift. The implementation moves these
/// strings into the models the spec names and pins them there.
@MainActor
final class CompanySetupMockCopyTests: XCTestCase {
    private typealias Copy = CompanySetupMockCopy

    func testWizardStepsAndHints() {
        XCTAssertEqual(Copy.railSteps,
                       ["Services", "Slack", "Google", "Atlassian", "Linear", "Microsoft 365", "Link deny list", "Publish"])
        XCTAssertEqual(Copy.stepLine(2), Copy.narrowStepLine)
        // The owner's first step: one row per supported service, the MCP note under them.
        XCTAssertEqual(Copy.servicesTitle, "What does your company use?")
        let services = ["Slack", "Google Workspace — Gmail and Calendar", "Atlassian — Jira and Confluence", "Linear",
                        "Microsoft 365 — Outlook"]
        XCTAssertEqual(Copy.services.map(\.0), services)
        XCTAssertTrue(Copy.mcpNote.contains("Connections → Quick Connections (MCP connectors)"))
        XCTAssertTrue(Copy.dropServiceBody.contains("dropped from the draft"))
        // D19: the fork offers Create new by default and a hint per vendor.
        XCTAssertEqual(Copy.createNew, "Create new")
        XCTAssertEqual(Copy.alreadyHaveOne, "We already have one")
        for hint in [Copy.notSureSlack, Copy.notSureGoogle, Copy.notSureAtlassian, Copy.notSureLinear, Copy.notSureMicrosoft] {
            XCTAssertTrue(hint.hasPrefix("Not sure? "), hint)
        }
        XCTAssertTrue(Copy.notCollaborator.contains("Ask the app's owner to add you as a collaborator"))
        XCTAssertEqual(Copy.confirmChecks.count, 3)
    }

    func testFailureCopySaysWhatIsKept() {
        XCTAssertTrue(Copy.publishTokenExpired.contains("Your setup is kept"))
        XCTAssertTrue(Copy.publishFailed.contains("Your setup is kept"))
        XCTAssertTrue(Copy.googleNetwork.hasSuffix("Nothing was saved."))
        XCTAssertTrue(Copy.tokenNetwork.hasSuffix("Nothing was saved."))
        XCTAssertTrue(Copy.slackProgressCaption.contains("never created twice"))
        XCTAssertTrue(Copy.tokenNote.contains("never stored"))
        XCTAssertTrue(Copy.replaceCaption.contains("Nothing leaves this Mac"))
    }

    func testParentSpecWordingIsVerbatim() {
        // Parent spec §4b, §5 and §2 name these texts word for word.
        XCTAssertEqual(Copy.tokenDead, "The API token stopped working (expired or revoked) — paste a new one")
        XCTAssertEqual(Copy.tokenMissingScope, "This token lacks read:jira-work — create one with the listed scopes.")
        XCTAssertTrue(Copy.googleBannerBody.contains("Move Gmail to your company's or your own Google project"))
        XCTAssertTrue(Copy.atlassianBannerBody.hasPrefix("Your company needs its own Atlassian app — ask your admin or set it up"))
        XCTAssertEqual(Copy.reloginNewLink, "Re-login needed — your company changed its app; open the new link")
        XCTAssertEqual(Copy.reloginUntied, "Re-login needed — open your company's link")
        XCTAssertEqual(Copy.mdmTitle, "Acme — Connect all")
        XCTAssertEqual(Copy.keepCurrent, "Keep current")
    }

    func testShippedTextsMatchTheApp() {
        XCTAssertEqual(Copy.blockedTitle, SourceBlockedNotice.title)
        XCTAssertEqual(Copy.connectionsTitle, "Connections")
    }

    func testEveryFrameHasAShotAndNamesAreUnique() {
        let names = CompanySetupShotFixtures.shots.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for frame in CompanySetupShotFixtures.Overview.allCases {
            XCTAssertTrue(names.contains("company-overview-\(frame.rawValue)"))
        }
        for scene in CompanyWizardScenes.scenes {
            XCTAssertTrue(names.contains("company-wizard-\(scene.name)"))
        }
        // The owner's rule: every screen has a narrow frame.
        for scene in ["services", "services-found", "services-change"] {
            XCTAssertTrue(names.contains("company-wizard-\(scene)"), scene)
        }
        for screen in ["wizard-services", "wizard-google-create", "connect-confirm", "overview-companies", "google-detail", "jira-detail",
                       "ownGoogle-empty", "token-empty"] {
            XCTAssertTrue(names.contains("company-\(screen)-narrow"), screen)
        }
    }
}
