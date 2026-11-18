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
        XCTAssertTrue(Copy.publishSummary[2].hasSuffix("checked and connected by your sign-in"))
        // Ask #1503: the check sign-in is the person's real connection; Discard keeps it.
        XCTAssertTrue(Copy.checkingGoogle.contains("connects your own Google account"))
        XCTAssertTrue(Copy.atlassianSigninWait.contains("connects your own Atlassian account"))
        XCTAssertTrue(Copy.discardConfirm.contains("stay connected"))
        XCTAssertTrue(Copy.publishedBody.hasSuffix("Connect this Mac adds the rest."))
        // The person setting up may not be an admin: the steps say who to ask.
        XCTAssertTrue(Copy.consentLinkValue.contains("/adminconsent?client_id="))
        XCTAssertTrue(Copy.noOrgBody.contains("Project Creator role"))
        XCTAssertTrue(Copy.draftUnreadableTitle.hasSuffix("start again"))
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
        XCTAssertEqual(Copy.blockedBody, SourceBlockedNotice.message)
        XCTAssertEqual(Copy.connectionsTitle, "Connections")
        // D21: the IT guide link's words live in ManagedPolicyHelp.
        XCTAssertEqual(Copy.itGuideLink, ManagedPolicyHelp.label)
        XCTAssertEqual(Copy.itGuideRow, ManagedPolicyHelp.rowTitle)
        XCTAssertEqual(Copy.itGuideCaption, ManagedPolicyHelp.rowCaption)
        XCTAssertEqual(Copy.policyTitle, OrganizationPolicySection.title)
        XCTAssertEqual(Copy.policyFooter, OrganizationPolicySection.footer)
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
        for scene in ["services", "services-found", "services-change", "draftUnreadable", "atlassian-signin",
                      "atlassian-signinFailed"] {
            XCTAssertTrue(names.contains("company-wizard-\(scene)"), scene)
        }
        // Narrow frames: exactly the set the spec lists (§12) — one per screen
        // family, and one per distinct wizard step layout.
        XCTAssertEqual(Set(names.filter { $0.hasSuffix("-narrow") }), Set(CompanySetupShotFixtures.narrowShots))
    }
}
