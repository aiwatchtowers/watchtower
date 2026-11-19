import WatchtowerCore
import WatchtowerTestSupport
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
    private typealias Model = CompanySetupWizardModel
    private typealias Guide = CompanyVendorGuide

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
        // The Slack app's name in its caption, and the section that adds an account (Task 25a).
        XCTAssertEqual(acme.vendors[.slack], Pres.slackAppDetail(appID: "A0ACME"))
        XCTAssertEqual(Copy.addAccountTitle, Pres.addAccountTitle)
        XCTAssertEqual(Copy.syncing, CompaniesZoneScenes.syncing)
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

    /// Task 25b: the Google and Jira details' list states, empty states and
    /// buttons (§4.2, §5.3, §6.4).
    func testGoogleAndJiraDetailCopyLivesInThePresentation() {
        XCTAssertEqual(Copy.accountsTitle, Pres.accountsTitle)
        XCTAssertEqual(Copy.googleTitle, Pres.googleTitle)
        XCTAssertEqual(Copy.jiraTitle, Pres.jiraTitle)
        XCTAssertEqual(Copy.googleEmpty, Pres.googleEmpty)
        XCTAssertEqual(Copy.jiraEmpty, Pres.jiraEmpty)
        XCTAssertEqual(Copy.googleLoading, Pres.googleLoading)
        XCTAssertEqual(Copy.jiraLoading, Pres.jiraLoading)
        XCTAssertEqual(Copy.googleReadFailed, Pres.readFailed(.google, "database is locked"))
        XCTAssertEqual(Copy.jiraReadFailed, Pres.readFailed(.atlassian, "database is locked"))
        XCTAssertEqual(Copy.tryAgain, Pres.tryAgain)
        XCTAssertEqual(Copy.connectCalendar, Pres.connectCalendar)
        XCTAssertEqual(Copy.connectCompanyAtlassian, Pres.connectCompanyApp("Acme", .atlassian))
        let google = Pres.detailActions(.google, companies: [], empty: true).map(\.title)
        XCTAssertEqual(google, [Copy.connectCalendar, Copy.useOwnGoogle, Copy.pasteCode])
        let jira = Pres.detailActions(.atlassian, companies: [], empty: true).map(\.title)
        XCTAssertEqual(jira, [Copy.connectTokenButton, Copy.pasteCode])
        XCTAssertEqual(Pres.detailActions(.atlassian, companies: [Self.acme], empty: false).map(\.title),
                       [Copy.connectCompanyAtlassian, Copy.connectTokenButton])
    }

    /// Task 21 moved the wizard's words into `CompanySetupWizardModel` and
    /// `CompanyVendorGuide`.
    func testWizardCopyLivesInTheModel() {
        XCTAssertEqual(Copy.wizardTitle, Model.wizardTitle)
        XCTAssertEqual(Copy.wizardIntro, Model.wizardIntro)
        XCTAssertEqual(Copy.railSteps, [Model.Step.services] .map(Model.railName)
            + CompanyVendor.allCases.map { Model.railName(.vendor($0)) } + [Model.railName(.denyList), Model.railName(.publish)])
        XCTAssertEqual([Copy.railDone, Copy.railReused, Copy.railSkipped, Copy.railWaiting],
                       [Model.StepMark.done, .reused, .skipped, .waiting].compactMap(Model.railWord))
        XCTAssertEqual(Copy.changeServices, Model.changeServices)
        XCTAssertEqual(Copy.skipStep, Model.skipStep)
        XCTAssertEqual(Copy.back, Model.backTitle)
        XCTAssertEqual(Copy.continueStep, Model.continueTitle)
        XCTAssertEqual(Copy.tryAgain, Model.tryAgainTitle)
        XCTAssertEqual(Copy.backToConnections, Model.backToConnections)
        // Services.
        XCTAssertEqual(Copy.servicesTitle, Guide.servicesTitle)
        XCTAssertEqual(Copy.servicesBody, Guide.servicesBody)
        XCTAssertEqual(Copy.services.map(\.0), CompanyVendor.allCases.map { Guide.servicesRow($0).title })
        XCTAssertEqual(Copy.services.map(\.1), CompanyVendor.allCases.map { Guide.servicesRow($0).detail })
        XCTAssertEqual(Copy.foundOnMac, Guide.foundOnMac)
        XCTAssertEqual(Copy.mcpNote, Guide.mcpNote)
        XCTAssertEqual(Copy.openQuickConnections, Guide.openQuickConnections)
        XCTAssertEqual(ConnectionService(rawValue: Guide.quickConnectionsService), .quickConnections)
        let drop = Model.dropWarningFor(.atlassian)
        XCTAssertEqual([Copy.dropServiceTitle, Copy.dropServiceBody, Copy.dropService, Copy.keepService],
                       [drop.title, drop.body, drop.drop, drop.keep])
        XCTAssertEqual(Copy.draftUnreadableTitle, Model.draftUnreadableTitle)
        XCTAssertEqual(Copy.draftUnreadableBody, Model.draftUnreadableBody(file: "draft.json.bad-20261118-0412"))
        XCTAssertEqual(Copy.showInFinder, Model.showInFinder)
        let nov17 = DateComponents(calendar: .current, year: 2026, month: 11, day: 17, hour: 12).date ?? Date()
        XCTAssertEqual(Copy.resumeLine, Model.resumeLine(started: nov17))
        XCTAssertEqual(Copy.discardSetup, Model.discardSetup)
        XCTAssertEqual(Copy.discardConfirm, Model.discardConfirm)
    }

    func testWizardVendorCopyLivesInTheModel() {
        // Existing apps first.
        XCTAssertEqual(Copy.lookingSlack, Guide.looking(.slack))
        XCTAssertEqual(Copy.foundTitle, Model.foundTitle)
        XCTAssertEqual(Copy.reuseCaption, Guide.reuseCaption(.slack))
        XCTAssertEqual(Copy.googleReuseCaption, Guide.reuseCaption(.google))
        XCTAssertEqual(Copy.useSelected, Model.useSelected)
        XCTAssertEqual(Copy.notFoundGoogle, Guide.notFound(.google))
        XCTAssertEqual(Copy.createNew, Model.createNew)
        XCTAssertEqual(Copy.alreadyHaveOne, Model.alreadyHaveOne)
        XCTAssertEqual(Copy.createNewDetail, Model.createNewDetail)
        XCTAssertEqual(Copy.alreadyHaveDetail, Model.alreadyHaveDetail)
        XCTAssertEqual([Copy.notSureSlack, Copy.notSureGoogle, Copy.notSureAtlassian, Copy.notSureLinear, Copy.notSureMicrosoft],
                       CompanyVendor.allCases.map(Guide.notSure))
        XCTAssertEqual(Copy.reuseSecretBody, Model.reuseSecretBody)
        XCTAssertEqual(Copy.openClient, Model.openClient)
        XCTAssertEqual(Copy.clientSecret, Guide.alreadyHaveFields(.google)[1].label)
        XCTAssertEqual(Copy.clientID, Guide.alreadyHaveFields(.atlassian)[0].label)
        // Slack.
        XCTAssertEqual([Copy.slackTokenStep1, Copy.slackTokenHelp, Copy.openTokenPage, Copy.slackTokenStep2,
                        Copy.tokenPlaceholder, Copy.tokenNote, Copy.createApp, Copy.updateApp],
                       [Model.slackTokenStep1, Model.slackTokenHelp, Model.openTokenPage, Model.slackTokenStep2,
                        Model.tokenPlaceholder, Model.tokenNote, Model.createApp, Model.updateApp])
        XCTAssertEqual(Copy.slackReuseSteps, ["Checking the token", Model.readingApp("A0ACME"), Model.comparingApp])
        XCTAssertEqual(Copy.slackProgressCaption, Model.slackProgressCaption)
        XCTAssertEqual(Copy.manifestDiffTitle, Model.manifestDiffTitle("A0ACME"))
        XCTAssertEqual(Copy.manifestDiffBody, Model.manifestDiffBody)
        XCTAssertEqual(Copy.manifestDiffLines, Model.diffLines(SlackAppChanges(
            addScopes: ["reactions:read", "users:read.email"], addRedirectURLs: ["http://127.0.0.1:18551/slack/callback"])))
        XCTAssertEqual(Copy.notCollaborator, Model.notCollaborator(appID: "A0ACME"))
        XCTAssertEqual(Copy.wrongWorkspace, SlackAppSetupModel.wrongWorkspaceLine(appID: "A0ACME", appTeam: "T0OTHER",
                                                                                  workspace: "acme"))
        XCTAssertEqual(Copy.slackSettingsLink, Guide.alreadyHaveFields(.slack)[0].label)
        XCTAssertEqual(Copy.slackSettingsHelp, Guide.alreadyHaveFields(.slack)[0].help)
        XCTAssertEqual(Copy.slackSettingsInvalid, Model.slackSettingsInvalid)
        XCTAssertEqual(Copy.badToken, SlackAppSetupModel.badTokenBody)
        // Google.
        XCTAssertEqual(Copy.googleGuide, Guide.guideLines(.google).map(\.text))
        XCTAssertEqual(Copy.dropJSON, Model.dropJSON)
        XCTAssertEqual(Copy.checkingGoogle, Model.checkingGoogle)
        XCTAssertEqual(Copy.googleRejected, Model.rejectedLine(.google, code: "invalid_client", tenant: ""))
        XCTAssertEqual(Copy.noOrgLink, Model.noOrgLink)
        XCTAssertEqual(Copy.noOrgTitle, Model.noOrgTitle)
        XCTAssertEqual(Copy.noOrgBody, Model.noOrgBody(domain: "example.com"))
        XCTAssertEqual(Copy.copyStepsForAdmin, Model.copyStepsForAdmin)
        XCTAssertEqual(Copy.googleNetwork, Model.networkLine(.google, "the request timed out"))
    }

    func testWizardPublishCopyLivesInTheModel() {
        // Atlassian.
        XCTAssertEqual(Copy.atlassianGuide, Guide.guideLines(.atlassian).map(\.text))
        XCTAssertEqual([Copy.copyScopes, Copy.copyCallbacks], [1, 2].compactMap { Guide.guideCopyButtons(.atlassian)[$0] })
        XCTAssertEqual(Copy.atlassianSigninWait, Model.atlassianSigninWait)
        XCTAssertEqual(Copy.atlassianSigninFailed, Model.rejectedLine(.atlassian, code: "invalid_client", tenant: ""))
        XCTAssertEqual(Copy.checkBySignin, Model.checkBySignin)
        XCTAssertEqual(Copy.publishWaitsAtlassian, Model.publishWaitsAtlassian)
        XCTAssertEqual(Copy.confirmTitle, Model.confirmTitle)
        XCTAssertEqual(Copy.confirmBody, Model.confirmBody)
        XCTAssertEqual(Copy.confirmChecks, Model.confirmChecks)
        // Linear and Microsoft.
        XCTAssertEqual(Copy.linearGuide, Guide.guideLines(.linear).map(\.text))
        XCTAssertEqual(Copy.copyCallback, Guide.guideCopyButtons(.linear)[1])
        XCTAssertEqual(Copy.linearNote, Guide.fieldsNote(.linear))
        XCTAssertEqual(Copy.microsoftGuide, Guide.guideLines(.microsoft).map(\.text))
        XCTAssertEqual(Copy.copyPermissions, Guide.guideCopyButtons(.microsoft)[2])
        XCTAssertEqual(Copy.microsoftNote, Guide.fieldsNote(.microsoft))
        XCTAssertEqual([Copy.microsoftClientID, Copy.microsoftTenantID], Guide.alreadyHaveFields(.microsoft).map(\.label))
        XCTAssertEqual(Copy.consentTitle, Model.consentTitle)
        XCTAssertEqual(Copy.consentBody, Model.consentBody)
        XCTAssertEqual(Copy.consentLinkLabel, Model.consentLinkLabel)
        XCTAssertEqual(Copy.checkAgain, Model.checkAgain)
        XCTAssertEqual(Copy.microsoftRejected, Model.rejectedLine(.microsoft, code: "AADSTS700016", tenant: "0000-acme"))
        // Deny list.
        XCTAssertEqual(Copy.denyTitle, Model.railName(.denyList))
        XCTAssertEqual(Copy.denyBody, Model.denyBody)
        XCTAssertEqual(Copy.addHost, Model.addHostLabel)
        XCTAssertEqual(Copy.add, Model.addTitle)
        XCTAssertEqual(Copy.denyInvalid, Model.denyInvalid)
        // Publish.
        XCTAssertEqual(Copy.companyName, Model.companyNameLabel)
        XCTAssertEqual(Copy.publishCaption, Model.publishCaption)
        XCTAssertEqual(Copy.publish, Model.publishTitle)
        XCTAssertEqual(Copy.publishSteps, Model.publishStepLines(slack: true).map(\.label))
        XCTAssertEqual(Copy.publishedTitle, Model.publishedTitle("Acme"))
        XCTAssertEqual(Copy.publishedBody, Model.publishedBody)
        XCTAssertEqual(Copy.publishedNoSlack, Model.publishedNoSlack)
        XCTAssertEqual([Copy.linkLabel, Copy.codeLabel, Copy.profileLabel, Copy.saveProfile],
                       [Model.linkLabel, Model.codeLabel, Model.profileLabel, Model.saveProfile])
        XCTAssertEqual(Copy.profileValue, Model.profileFileName("Acme"))
        XCTAssertEqual(Copy.connectThisMac, Model.connectThisMacTitle)
        XCTAssertEqual(Copy.publishTokenExpired, Model.publishTokenExpiredLine)
        XCTAssertEqual(Copy.publishNeedsToken, Model.publishNeedsTokenLine)
        XCTAssertEqual(Copy.itGuideLink, ManagedPolicyHelp.label)
        XCTAssertEqual(Copy.publishSummary[3], Guide.notUsedLine(.linear, skipped: true))
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
        for name in ["confirm", "confirm-code", "confirm-again", "confirm-mdm", "chain", "chain-failed", "done", "replace"] {
            XCTAssertTrue(names.contains("company-connect-\(name)"), name)
        }
        for name in ["open", "refused", "newerVersion"] {
            XCTAssertTrue(names.contains("company-page-\(name)"), name)
        }
    }

    /// Task 10 writes the listener's pages; Go's fixture holds their texts.
    func testGoPagesMatchMockCopy() throws {
        let pages = try CompanyPagesFixture.load()
        XCTAssertEqual(pages.open.heading, Copy.pageOpenHeading)
        XCTAssertEqual(pages.open.messageAcme, Copy.pageOpenBody)
        XCTAssertEqual(pages.refused.heading, Copy.pageRefusedHeading)
        XCTAssertEqual(pages.refused.reasons?["damaged"], Copy.pageRefusedBody)
        XCTAssertEqual(pages.refused.hint, Copy.pageRefusedHint)
        XCTAssertEqual(pages.refused.reasons?.count, 4, "damaged, too_long, site_not_https, personal")
        XCTAssertEqual(pages.newer.heading, Copy.pageNewerHeading)
        XCTAssertEqual(pages.newer.message, Copy.pageNewerBody)
        // The two pages without a shot (screens §3.4).
        XCTAssertEqual(pages.busy.heading, "Another link is waiting")
        XCTAssertEqual(pages.notTaken.heading, "Watchtower did not take this link")
    }

    /// Task 23 moved the connect sheet's words into `CompanyConnectFlowModel`;
    /// the shots render that model, so each scene says what the mockup said.
    func testConnectCopyLivesInTheFlowModel() async {
        typealias Flow = CompanyConnectFlowModel
        XCTAssertEqual(Copy.confirmCaption, Flow.confirmCaption)
        XCTAssertEqual(Copy.alreadyConnected, Flow.alreadyConnected)
        XCTAssertEqual(Copy.chainCaption, Flow.chainCaption)
        XCTAssertEqual(Copy.chainDoneBody, Flow.chainDoneBody)
        XCTAssertEqual(Copy.replaceBody, Flow.replaceBody)
        XCTAssertEqual(Copy.replaceCaption, Flow.replaceCaption)
        XCTAssertEqual(Copy.blockedTitle, Flow.blocked)
        XCTAssertEqual(Copy.codeInvalid, Flow.codeInvalid)
        XCTAssertEqual([Copy.cancel, Copy.connect, Copy.stop, Copy.skipService, Copy.done, Copy.replace, Copy.keepCurrent],
                       [Flow.cancelTitle, Flow.connectTitle, Flow.stopTitle, Flow.skipTitle, Flow.doneTitle,
                        Flow.replaceTitle, Flow.keepCurrentTitle])

        let scenes = Dictionary(uniqueKeysWithValues: CompanyConnectShots.scenes.map { ($0.0, $0.1()) })
        func details(_ name: String) -> [String?] {
            guard let model = scenes[name] else { return [] }
            return model.rows.map { model.progress($0).detail }
        }
        XCTAssertEqual(scenes["confirm"]?.title, Copy.confirmConnectTitle)
        XCTAssertEqual(scenes["confirm"]?.body, Copy.confirmLinkBody)
        XCTAssertEqual(scenes["confirm-again"]?.body, Copy.confirmLinkBody)
        XCTAssertEqual(scenes["confirm-code"]?.body, Copy.confirmCodeBody)
        XCTAssertEqual(scenes["confirm-mdm"]?.title, Copy.mdmTitle)
        XCTAssertEqual(scenes["confirm-mdm"]?.body, Copy.mdmBody)
        XCTAssertEqual(scenes["chain"]?.title, Copy.chainTitle)
        XCTAssertEqual(details("chain"), [Copy.chainSlackDone, Copy.chainBrowserGoogle, Copy.chainNext, nil, nil])
        XCTAssertEqual(details("chain-failed"),
                       [Copy.chainSlackDone, Copy.chainDenied, Copy.chainBrowserAtlassian, Copy.chainNext, nil])
        XCTAssertEqual(scenes["done"]?.title, Copy.chainDonePartial)
        XCTAssertEqual(details("done"), [nil, Copy.notConnected, nil, nil, Copy.chainSkipped])
        XCTAssertEqual(scenes["replace"]?.title, Copy.replaceTitle)
        if case let .replace(changes) = scenes["replace"]?.phase {
            XCTAssertEqual(changes.map(\.line), Copy.replaceLines)
        } else {
            XCTFail("replace scene")
        }
        let failed = Flow.preview(.chain, company: "Acme", slug: "acme", rows: [
            Flow.VendorRow(vendor: .google, title: "Gmail and Calendar", detail: "example.com", ticked: true,
                           state: .failed("the request timed out"))
        ], host: SlackConnectListenerHost(streamer: FakeCLILineStream()))
        XCTAssertEqual(failed.rows.map { failed.progress($0).detail }, [Copy.chainFailed])
        let all = Flow.preview(.done, company: "Acme", slug: "acme", rows: [
            Flow.VendorRow(vendor: .slack, title: "Slack", detail: "workspace acme", ticked: true, state: .connected(label: ""))
        ], host: SlackConnectListenerHost(streamer: FakeCLILineStream()))
        XCTAssertEqual(all.title, Copy.chainDoneAll)

        // The rows' words come from Go's inspect answer, not from the mockup.
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let flow = Flow(host: host) { fake }
        fake.enqueue(.init(lines: [#"{"company":"Acme","slug":"acme","state":"new","forced":false,"#
            + #""vendors":["slack","google","atlassian","microsoft","linear"],"connected":{},"changes":[],"forbidden":[],"#
            + #""details":{"google":{"client_id":"x","domain":"example.com"},"#
            + #""atlassian":{"client_id":"y","site":"https://acme.atlassian.net","confluence":true}}}"#]))
        let error = await flow.paste("eyJ2IjoxfQ")
        XCTAssertNil(error)
        XCTAssertEqual(flow.rows.map(\.title), Copy.vendorRows.map(\.0))
        XCTAssertEqual(flow.rows.map(\.detail), Copy.vendorRows.map(\.1))
    }
}
