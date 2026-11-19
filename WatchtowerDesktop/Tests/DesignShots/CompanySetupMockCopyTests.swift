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
    private typealias Pres = CompanyConnectionsPresentation

    private static let acme = CompanyRef(slug: "acme", name: "Acme", vendors: [
        .slack: "Watchtower (A0ACME)", .google: "example.com", .atlassian: "https://acme.atlassian.net",
        .linear: "", .microsoft: "0000-acme"
    ])

    private func account(
        _ vendor: CompanyVendor,
        _ label: String,
        slug: String = "",
        shared: Bool = false,
        status: String = "ok",
        error: String = ""
    ) -> AccountRef {
        AccountRef(vendor: vendor, accountID: 1, label: label, companySlug: slug, status: status, error: error,
                   sharedApp: shared)
    }

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
        // D15 amended (ask #1600): a Re-login banner, no countdown.
        XCTAssertEqual(Copy.atlassianBannerTitle, "Watchtower's shared Atlassian app is retired")
        XCTAssertEqual(Copy.atlassianBannerBody, "Your company needs its own Atlassian app — ask your admin or set it up. "
            + "Sign old.atlassian.net in again through your company's app or with an API token.")
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

    /// Task 24 moved the Connections words into `CompanyConnectionsPresentation`.
    func testConnectionsCopyLivesInThePresentation() {
        let acme = Self.acme
        XCTAssertEqual(Copy.companiesTitle, Pres.companiesTitle)
        XCTAssertEqual(Copy.companiesLoading, Pres.companiesLoading)
        XCTAssertEqual(Copy.companiesEmpty, Pres.companiesEmpty)
        XCTAssertEqual(Copy.portBusy, Pres.portBusyLine)
        XCTAssertEqual(Copy.codePlaceholder, Pres.codePlaceholder)
        XCTAssertEqual(Copy.codeInvalid, Pres.codeInvalid)
        XCTAssertEqual(Copy.setUpForCompany, CompaniesZoneState.Action.setUpForCompany.title)
        XCTAssertEqual(Copy.connectWithCode, CompaniesZoneState.Action.connectWithCode.title)
        XCTAssertEqual(Copy.continueSetup, SetupLine.Action.continueSetup.title)
        XCTAssertEqual(Copy.connectRest, CompanyCard.Action.connectRest.title)
        XCTAssertEqual(Copy.connectAll, CompanyCard.Action.connectAll.title)
        XCTAssertEqual(Copy.relogin, RowStatus.Action.relogin.title)
        XCTAssertEqual(Copy.connect, RowStatus.Action.connect.title)
        XCTAssertEqual(Copy.pasteCode, RowStatus.Action.pasteCode.title)
        XCTAssertEqual(Copy.pasteNewToken, RowStatus.Action.pasteNewToken.title)
        XCTAssertEqual(Copy.useOwnGoogle, CompanyBanner.Action.useOwnGoogle.title)
        XCTAssertEqual(Copy.connectTokenButton, CompanyBanner.Action.connectWithToken.title)
        XCTAssertEqual(Copy.setupInProgress, Pres.zone(
            companies: [], errors: [], draft: .inProgress(company: "Acme", step: "Atlassian", index: 3, count: 8),
            accounts: [], portBusy: false, loading: false
        ).setup?.text)
        XCTAssertEqual(Copy.companiesReadFailed, "Could not read the company setups: acme.json is damaged.")
        let failed = Pres.zone(companies: [], errors: [CompanyFileError(file: "acme.json", error: "x")], draft: nil,
                               accounts: [], portBusy: false, loading: false)
        XCTAssertEqual(failed.body, .readFailed(Copy.companiesReadFailed))
        let card = Pres.zone(companies: [acme], errors: [], draft: nil, accounts: [
            account(.slack, "acme", slug: "acme"), account(.atlassian, "acme.atlassian.net", slug: "acme"),
            account(.microsoft, "alice@example.com", slug: "acme")
        ], portBusy: false, loading: false).body.cards.first
        XCTAssertEqual(card?.line, Copy.companyCount)
        XCTAssertEqual(card?.missingLine, Copy.companyMissing)
        let mdm = CompanyRef(slug: "acme", name: "Acme", forced: true, vendors: acme.vendors)
        XCTAssertEqual(Pres.zone(companies: [mdm], errors: [], draft: nil, accounts: [], portBusy: false, loading: false)
            .body.cards.first?.line, Copy.companyMDMLine)
        let changed = account(.atlassian, "acme.atlassian.net", slug: "acme", status: "error", error: "company_changed_app")
        XCTAssertEqual(Pres.zone(companies: [acme], errors: [], draft: nil, accounts: [changed], portBusy: false, loading: false)
            .body.cards.first?.problemLine, Copy.companyRelogin)
        XCTAssertEqual(Copy.reloginChanged, Pres.reloginChanged("Acme"))
        XCTAssertEqual(Copy.reloginNewLink, Pres.reloginNewLink)
        XCTAssertEqual(Copy.reloginUntied, Pres.reloginUntied)
        XCTAssertEqual(Copy.rowNotConnected, Pres.notConnectedStatus.text)
        XCTAssertEqual(Copy.stoppedByPolicy, Pres.stoppedByPolicyLine)
        XCTAssertEqual(Copy.tokenDead, Pres.tokenDead)
        XCTAssertEqual(Copy.tokenTag, Pres.tokenTag)
        XCTAssertEqual(Copy.sharedTag, Pres.sharedTag)
        let utc = TimeZone(identifier: "UTC") ?? .current
        let due = ISO8601DateFormatter().date(from: "2026-12-18T10:00:00Z") ?? Date()
        XCTAssertEqual(Copy.tokenLease, Pres.tokenLease(due, zone: utc))
    }

    func testConnectionsGroupsAndBannersLiveInThePresentation() {
        let acme = Self.acme
        // Group titles and captions.
        XCTAssertEqual(Copy.groupOwnGoogle, Pres.groupOwnGoogle)
        XCTAssertEqual(Copy.groupOwnGoogleCaption, Pres.groupOwnGoogleCaption)
        XCTAssertEqual(Copy.groupShared, Pres.groupShared)
        XCTAssertEqual(Copy.groupSharedGoogleCaption, Pres.groupSharedGoogleCaption)
        XCTAssertEqual(Copy.groupSharedLinear, Pres.groupSharedLinear)
        XCTAssertEqual(Copy.groupSharedMicrosoft, Pres.groupSharedMicrosoft)
        XCTAssertEqual(Copy.groupTokens, Pres.groupTokens)
        XCTAssertEqual(Copy.groupTokensCaption, Pres.groupTokensCaption)
        XCTAssertEqual(Copy.groupUnknown, Pres.groupUnknown)
        XCTAssertEqual(Copy.groupUnknownCaption, Pres.groupUnknownCaption)
        let captions = [CompanyVendor.google, .atlassian, .slack, .linear, .microsoft].map { v in
            Pres.groups(vendor: v, accounts: [account(v, "x", slug: "acme")], companies: [acme]) { _ in false }
                .first?.caption
        }
        XCTAssertEqual(captions, [Copy.groupAcmeGoogle, Copy.groupAcmeAtlassian, Copy.groupAcmeSlack, Copy.groupAcmeLinear,
                                  Copy.groupAcmeMicrosoft])
        // Banners and locks.
        let google = Pres.banner(.google, accounts: [account(.google, "bob@example.org", shared: true)])
        XCTAssertEqual(google?.title, Copy.googleBannerTitle)
        XCTAssertEqual(google?.body, Copy.googleBannerBody)
        let jira = Pres.banner(.atlassian, accounts: [account(.atlassian, "old.atlassian.net", shared: true)])
        XCTAssertEqual(jira?.title, Copy.atlassianBannerTitle)
        XCTAssertEqual(jira?.body, Copy.atlassianBannerBody)
        XCTAssertEqual(Copy.ownGoogleLocked, Pres.lockCard(.ownGoogleProject).text)
        XCTAssertEqual(Copy.tokenLocked, Pres.lockCard(.atlassianAPIToken).text)
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
