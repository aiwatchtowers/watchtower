import Foundation
@testable import WatchtowerCore
import XCTest

/// Screens spec §4, §6.3, §7, §5.4/§6.5: the Companies zone, the account
/// groups, the row states, the banners and the lock cards.
final class CompanyConnectionsPresentationTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    private let acme = CompanyRef(slug: "acme", name: "Acme", vendors: [
        .slack: "Watchtower (A0ACME)", .google: "example.com", .atlassian: "https://acme.atlassian.net",
        .linear: "", .microsoft: "0000-acme"
    ])

    private func account(
        _ vendor: CompanyVendor,
        _ id: Int,
        _ label: String,
        slug: String = "",
        status: String = "ok",
        error: String = "",
        authKind: String = "oauth",
        shared: Bool = false
    ) -> AccountRef {
        AccountRef(vendor: vendor, accountID: id, label: label, companySlug: slug, status: status, error: error,
                   authKind: authKind, sharedApp: shared)
    }

    private func zone(
        companies: [CompanyRef] = [],
        errors: [CompanyFileError] = [],
        draft: CompanySetupDraftRef? = nil,
        accounts: [AccountRef] = [],
        portBusy: Bool = false,
        loading: Bool = false
    ) -> CompaniesZoneState {
        Pres.zone(companies: companies, errors: errors, draft: draft, accounts: accounts, portBusy: portBusy, loading: loading)
    }

    // MARK: - Companies zone

    func testZoneForPrivateUserIsOneInvitingLine() {
        let state = zone()
        XCTAssertEqual(state.body, .empty("Using Watchtower at work? Connect with your company's link or code, "
            + "or set it up for your company."))
        XCTAssertNil(state.setup)
        XCTAssertNil(state.portBusy)
        XCTAssertNil(state.problem)
        XCTAssertEqual(state.actions, [.setUpForCompany, .connectWithCode])
        XCTAssertEqual(state.actions.map(\.title), ["Set up for my company", "Connect with a company code"])
        // A personal bundle (own Google project) is not a company.
        let personal = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.google: ""])
        XCTAssertEqual(zone(companies: [personal]).body, state.body)
    }

    func testSetupInProgressRow() {
        let draft = CompanySetupDraftRef.inProgress(company: "Acme", step: "Atlassian", index: 3, count: 8)
        let state = zone(draft: draft)
        XCTAssertEqual(state.setup, SetupLine(text: "Setup in progress: Acme, at Atlassian (step 4 of 8).", action: .continueSetup))
        XCTAssertEqual(SetupLine.Action.continueSetup.title, "Continue setup")
        XCTAssertEqual(state.body, .cards([]), "the draft row replaces the inviting line")
        XCTAssertEqual(state.actions, [.connectWithCode], "Continue setup is the way back into the wizard")
        // With a stored company the draft row comes first, over the cards.
        let withCompany = zone(companies: [acme], draft: draft)
        XCTAssertNotNil(withCompany.setup)
        XCTAssertEqual(withCompany.body.cards.map(\.name), ["Acme"])
        // A draft not yet named.
        let unnamed = zone(draft: .inProgress(company: "", step: "Services", index: 0, count: 3))
        XCTAssertEqual(unnamed.setup?.text, "Setup in progress, at Services (step 1 of 3).")
        // An unreadable draft is not "no draft": the wizard shows the warning.
        let bad = zone(draft: .unreadable)
        XCTAssertEqual(bad.setup, SetupLine(text: "Your unfinished setup could not be read — start again",
                                            action: .setUpForCompany))
        XCTAssertEqual(bad.actions, [.connectWithCode])
    }

    func testUnconnectedVendorsShowConnect() {
        let accounts = [
            account(.slack, 1, "acme", slug: "acme"),
            account(.atlassian, 2, "acme.atlassian.net", slug: "acme"),
            account(.microsoft, 3, "alice@example.com", slug: "acme"),
            // Removed or purged: not connected any more; another company's or untied: not Acme's.
            account(.linear, 4, "Acme", slug: "acme", status: "removed"),
            account(.google, 5, "bob@example.org")
        ]
        let card = zone(companies: [acme], accounts: accounts).body.cards[0]
        XCTAssertEqual(card.line, "3 of 5 services connected")
        XCTAssertEqual(card.missingLine, "Not connected: Gmail and Calendar, Linear")
        XCTAssertNil(card.problemLine)
        XCTAssertEqual(card.actions, [.connectRest])
        XCTAssertEqual(CompanyCard.Action.connectRest.title, "Connect the rest")
        XCTAssertFalse(card.managed)
        XCTAssertEqual(zone(companies: [acme], accounts: accounts).actions, [.setUpForCompany, .connectWithCode])

        // In a detail: the vendor of a stored company with no account is a Not connected row.
        let groups = Pres.groups(vendor: .linear, accounts: accounts, companies: [acme]) { _ in false }
        XCTAssertEqual(groups.first?.rows, [.account(accounts[3]), .notConnected(.linear)])
        let status = Pres.notConnectedStatus
        XCTAssertEqual(status.text, "Not connected")
        XCTAssertEqual(status.tone, .gray)
        XCTAssertEqual(status.action, .connect)
        XCTAssertEqual(RowStatus.Action.connect.title, "Connect")

        // Every vendor connected: no missing line, no button.
        let all = CompanyVendor.allCases.enumerated().map { account($0.element, $0.offset, "x", slug: "acme") }
        let full = zone(companies: [acme], accounts: all).body.cards[0]
        XCTAssertEqual(full.line, "5 of 5 services connected")
        XCTAssertNil(full.missingLine)
        XCTAssertEqual(full.actions, [])
        // Connected means an ok account, as `company inspect` counts it: a revoked or rejected one is not.
        let broken = [account(.linear, 1, "Acme", slug: "acme", status: "revoked"),
                      account(.google, 2, "x", slug: "acme", status: "error", error: "invalid_client")]
        let brokenCard = zone(companies: [acme], accounts: all.filter { $0.vendor != .linear && $0.vendor != .google } + broken)
            .body.cards[0]
        XCTAssertEqual(brokenCard.line, "3 of 5 services connected")
        XCTAssertEqual(brokenCard.missingLine, "Not connected: Gmail and Calendar, Linear")
        // One vendor: "service", not "services".
        let one = CompanyRef(slug: "beta", name: "Beta", vendors: [.linear: ""])
        XCTAssertEqual(zone(companies: [one]).body.cards[0].line, "0 of 1 service connected")
    }

    func testPortBusyLine() {
        let state = zone(portBusy: true)
        XCTAssertEqual(state.portBusy,
                       "Company links cannot reach Watchtower: port 18551 is busy. Paste the company code here instead.")
        XCTAssertTrue(state.codeFieldOpen)
        XCTAssertEqual(zone(companies: [acme], portBusy: true).portBusy, state.portBusy)
        let withDraft = zone(draft: .unreadable, portBusy: true)
        XCTAssertEqual(withDraft.portBusy, state.portBusy)
        XCTAssertNotNil(withDraft.setup)
        XCTAssertFalse(zone().codeFieldOpen)
        XCTAssertEqual(Pres.codePlaceholder, "Company code")
        XCTAssertEqual(Pres.connect, "Connect")
    }

    func testDamagedFileIsNotEmpty() {
        let damaged = [CompanyFileError(file: "acme.json", error: "unexpected end of JSON input")]
        let state = zone(errors: damaged)
        XCTAssertEqual(state.body, .readFailed("Could not read the company setups: acme.json is damaged."))
        XCTAssertEqual(state.actions, [], "Try again is the only way out")
        XCTAssertNil(state.setup)
        XCTAssertEqual(Pres.tryAgain, "Try again")
        // `company list` failed as a whole: never "no company".
        let listFailed = Pres.zone(companies: [], errors: [], draft: nil, accounts: [], portBusy: false, loading: false,
                                   listError: "exit status 1")
        XCTAssertEqual(listFailed.body, .readFailed("Could not read the company setups: exit status 1."))
        // Two files.
        let two = damaged + [CompanyFileError(file: "beta.json", error: "x")]
        XCTAssertEqual(zone(errors: two).body, .readFailed("Could not read the company setups: acme.json and beta.json are damaged."))
        // Beside a readable company: the cards stay, the damage is a line.
        let mixed = zone(companies: [acme], errors: damaged)
        XCTAssertEqual(mixed.body.cards.count, 1)
        XCTAssertEqual(mixed.problem, "Could not read the company setups: acme.json is damaged.")
        // The draft's own read error is the draft's state, never a company file's.
        let draftOnly = zone(errors: [CompanyFileError(file: "draft.json", error: "x")], draft: .unreadable)
        XCTAssertEqual(draftOnly.body, .cards([]))
        // Loading wins over everything; nothing else shows.
        let loading = zone(errors: damaged, portBusy: true, loading: true)
        XCTAssertEqual(loading.body, .loading("Reading company setups…"))
        XCTAssertNil(loading.portBusy)
        XCTAssertEqual(loading.actions, [])
    }

    func testMDMCompanyIsProminent() {
        let forced = CompanyRef(slug: "acme-mdm", name: "Acme", forced: true, vendors: acme.vendors)
        let other = CompanyRef(slug: "aaa", name: "AAA", vendors: [.linear: ""])
        let cards = zone(companies: [other, forced]).body.cards
        XCTAssertEqual(cards.map(\.slug), ["acme-mdm", "aaa"], "the managed company comes first")
        let card = cards[0]
        XCTAssertTrue(card.managed)
        XCTAssertEqual(card.line, "Set up by your organization · nothing connected yet")
        XCTAssertNil(card.missingLine)
        XCTAssertEqual(card.actions, [.connectAll])
        XCTAssertTrue(CompanyCard.Action.connectAll.isProminent)
        XCTAssertEqual(CompanyCard.Action.connectAll.title, "Connect all")
        XCTAssertFalse(CompanyCard.Action.connectRest.isProminent)
        // Once something is connected it reads like any card, still managed.
        let some = zone(companies: [forced], accounts: [account(.slack, 1, "acme", slug: "acme-mdm")]).body.cards[0]
        XCTAssertEqual(some.line, "1 of 5 services connected")
        XCTAssertEqual(some.actions, [.connectRest])
        XCTAssertTrue(some.managed)
    }

    // MARK: - Row states

    func testInvalidClientRow() {
        let a = account(.google, 1, "dave@example.com", slug: "acme", status: "error", error: "invalid_client")
        let status = Pres.rowStatus(a, purgeLease: nil, companies: [acme])
        XCTAssertEqual(status, RowStatus(text: "Re-login needed — your company changed its app; open the new link",
                                         tone: .error, action: .pasteCode))
        XCTAssertEqual(RowStatus.Action.pasteCode.title, "Paste a company code")
        XCTAssertTrue(status?.needsAttention == true)
    }

    func testUntiedRow() {
        let a = account(.slack, 2, "acme-labs", status: "error", error: "unknown_client")
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: []),
                       RowStatus(text: "Re-login needed — open your company's link", tone: .error, action: .pasteCode))
        let groups = Pres.groups(vendor: .slack, accounts: [a], companies: [acme]) { _ in false }
        let other = groups.first { $0.kind == .other }
        XCTAssertEqual(other?.title, "Other accounts")
        XCTAssertEqual(other?.caption, "Signed in through an app this Watchtower no longer knows")
        XCTAssertEqual(other?.rows, [.account(a)])
    }

    func testReplacedRow() {
        let a = account(.google, 1, "alice@example.com", slug: "acme", status: "error", error: "company_changed_app")
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: [acme]),
                       RowStatus(text: "Re-login needed — Acme changed its app", tone: .error, action: .relogin))
        XCTAssertEqual(RowStatus.Action.relogin.title, "Re-login")
        // Its company's card names it, with the Re-login of the changed vendors.
        let card = zone(companies: [acme], accounts: [a]).body.cards[0]
        XCTAssertEqual(card.problemLine, "Google: Re-login needed — Acme changed its app")
        XCTAssertEqual(card.actions, [.relogin([.google]), .connectRest])
        XCTAssertFalse(card.missingLine?.contains("Gmail") ?? true, "a Replace's vendor is not also Not connected")
        XCTAssertEqual(CompanyCard.Action.relogin([.google]).title, "Re-login")
        let atl = account(.atlassian, 2, "acme.atlassian.net", slug: "acme", status: "error", error: "company_changed_app")
        XCTAssertEqual(zone(companies: [acme], accounts: [atl]).body.cards[0].problemLine,
                       "Atlassian: Re-login needed — Acme changed its app")
        // The stored bundle is gone: nothing to re-login with, the new link is the way.
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: []),
                       RowStatus(text: "Re-login needed — your company changed its app; open the new link",
                                 tone: .error, action: .pasteCode))
    }

    func testReloginRowsAreAttentionNotConnectedIsNot() {
        for code in ["company_changed_app", "invalid_client", "unknown_client", "api_token_dead"] {
            let a = account(.atlassian, 1, "x", slug: "acme", status: "error", error: code)
            XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: [acme])?.needsAttention, true, code)
        }
        XCTAssertFalse(Pres.notConnectedStatus.needsAttention)
        XCTAssertFalse(Pres.rowStatus(account(.google, 1, "x"), purgeLease: nil, companies: [], stoppedByPolicy: true)?.needsAttention ?? true)
        // A plain ok account and an unrelated error keep today's status line.
        XCTAssertNil(Pres.rowStatus(account(.google, 1, "x"), purgeLease: nil, companies: []))
        XCTAssertNil(Pres.rowStatus(account(.google, 1, "x", status: "error", error: "network down"), purgeLease: nil, companies: []))
        // The PDR scope hint keeps the account syncing: not attention, but it asks for the Re-login.
        let pdr = Pres.rowStatus(account(.atlassian, 1, "x", slug: "acme", error: "pdr_scope_missing"), purgeLease: nil, companies: [])
        XCTAssertEqual(pdr, RowStatus(text: "Re-login to finish the setup", tone: .secondary, action: .relogin))
        XCTAssertFalse(pdr?.needsAttention ?? true)
    }

    func testStoppedByPolicyRow() {
        let a = account(.atlassian, 1, "beta.atlassian.net", status: "error", error: "api_token_dead", authKind: "api_token")
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: [], stoppedByPolicy: true),
                       RowStatus(text: "Stopped by your organization — data kept", tone: .gray, action: nil))
        // A purged row's data is not kept: today's line stays.
        let purged = account(.atlassian, 1, "beta.atlassian.net", status: "purged", authKind: "api_token")
        XCTAssertNil(Pres.rowStatus(purged, purgeLease: nil, companies: [], stoppedByPolicy: true))
    }

    func testReplaceThatDroppedTheVendorAsksForTheNewLink() {
        // A Replace whose new bundle has no Google block: no app to re-login with.
        let noGoogle = CompanyRef(slug: "acme", name: "Acme", vendors: [.slack: ""])
        let a = account(.google, 1, "alice@example.com", slug: "acme", status: "error", error: "company_changed_app")
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: [noGoogle]),
                       RowStatus(text: "Re-login needed — your company changed its app; open the new link",
                                 tone: .error, action: .pasteCode))
    }

    func testPDRHintOnlyOnAHealthyRow() {
        for status in ["revoked", "error", "purged", "removed"] {
            let a = account(.atlassian, 1, "x", slug: "acme", status: status, error: "pdr_scope_missing")
            XCTAssertNil(Pres.rowStatus(a, purgeLease: nil, companies: [acme]), status)
        }
    }

    func testRetiredSharedJiraStaysInSharedGroup() {
        // The retired shared client is unknown to the build, yet the row stays in its group.
        let a = account(.atlassian, 1, "old.atlassian.net", status: "error", error: "unknown_client", shared: true)
        let groups = Pres.groups(vendor: .atlassian, accounts: [a], companies: []) { _ in false }
        XCTAssertEqual(groups.map(\.kind), [.shared])
        XCTAssertEqual(Pres.tag(a), "Shared app")
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: nil, companies: [])?.text, "Re-login needed — open your company's link")
    }

    func testGroupOrder() {
        let accounts = [
            account(.google, 1, "erin@example.com", status: "error", error: "unknown_client"),
            account(.google, 2, "bob@example.org", shared: true),
            account(.google, 3, "alice@example.net"),
            account(.google, 4, "alice@example.com", slug: "acme"),
            account(.google, 5, "me@example.net", slug: "me")
        ]
        let personal = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.google: ""])
        let groups = Pres.groups(vendor: .google, accounts: accounts, companies: [personal, acme]) { $0.accountID == 3 }
        XCTAssertEqual(groups.map(\.kind), [.company("acme"), .ownProject, .shared, .other])
        XCTAssertEqual(groups.map(\.title), ["Acme", "Your own Google project", "Watchtower's shared app", "Other accounts"])
        XCTAssertEqual(groups.map(\.caption), ["Acme's Google project · example.com", "Gmail and Calendar through a project you own",
                                               "Calendar only", "Signed in through an app this Watchtower no longer knows"])
        XCTAssertEqual(groups[1].rows, [.account(accounts[2]), .account(accounts[4])])
        XCTAssertEqual(Pres.tag(accounts[1]), "Shared app")
        XCTAssertNil(Pres.tag(accounts[2]))
        XCTAssertEqual(Pres.syncingLine(accounts[1]), "Syncing through the shared app")
        XCTAssertEqual(Pres.syncingLine(accounts[2]), "Syncing")

        // Jira: company → API tokens → shared → other; no own project.
        let jira = [
            account(.atlassian, 1, "old.atlassian.net", shared: true),
            account(.atlassian, 2, "beta.atlassian.net", authKind: "api_token"),
            account(.atlassian, 3, "acme.atlassian.net", slug: "acme"),
            account(.atlassian, 4, "gone.atlassian.net", slug: "deleted-co")
        ]
        let jiraGroups = Pres.groups(vendor: .atlassian, accounts: jira, companies: [acme]) { _ in true }
        XCTAssertEqual(jiraGroups.map(\.kind), [.company("acme"), .apiTokens, .shared, .other])
        XCTAssertEqual(jiraGroups.map(\.caption), ["Acme's Atlassian app · acme.atlassian.net", "Sites connected with your own token",
                                                   nil, "Signed in through an app this Watchtower no longer knows"])
        XCTAssertEqual(jiraGroups[1].title, "API tokens")
        XCTAssertEqual(Pres.tag(jira[1]), "API token")
        XCTAssertEqual(jiraGroups[3].rows, [.account(jira[3])], "a tie to a company no longer stored")

        // Captions of the other vendors' company and shared groups.
        func titles(_ v: CompanyVendor) -> [String?] {
            let groups = Pres.groups(vendor: v, accounts: [account(v, 9, "x", slug: "acme"), account(v, 8, "y")],
                                     companies: [acme]) { _ in true }
            return groups.flatMap { [$0.title, $0.caption] }
        }
        XCTAssertEqual(titles(.slack), ["Acme", "Acme's Slack app · Watchtower (A0ACME)", "Watchtower's shared app", nil])
        XCTAssertEqual(titles(.linear), ["Acme", "Acme's Linear app", "Watchtower's Linear app", nil])
        XCTAssertEqual(titles(.microsoft), ["Acme", "Acme's Microsoft 365 app · tenant 0000-acme", "Watchtower's Microsoft app", nil])
        // An empty group is not shown; a company without this vendor and without accounts has none.
        let noVendor = CompanyRef(slug: "beta", name: "Beta", vendors: [.slack: ""])
        XCTAssertEqual(Pres.groups(vendor: .linear, accounts: [], companies: [noVendor]) { _ in false }, [])
    }

    func testDeadTokenRowAndLeaseNote() throws {
        let a = account(.atlassian, 2, "beta.atlassian.net", status: "error", error: "api_token_dead", authKind: "api_token")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let none = Pres.rowStatus(a, purgeLease: nil, companies: [], zone: utc)
        XCTAssertEqual(none, RowStatus(text: "The API token stopped working (expired or revoked) — paste a new one",
                                       tone: .error, action: .pasteNewToken))
        XCTAssertNil(none?.note, "no lease counting, no note")
        XCTAssertEqual(RowStatus.Action.pasteNewToken.title, "Paste a new token")
        let due = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-18T10:00:00Z"))
        XCTAssertEqual(Pres.rowStatus(a, purgeLease: due, companies: [], zone: utc)?.note,
                       "Its data stays. If no new token comes, the 30-day rule deletes it on Dec 18, "
                           + "with a notice 72 hours before.")
        // The note belongs to the dead token only.
        let other = account(.atlassian, 3, "x", slug: "acme", status: "error", error: "invalid_client")
        XCTAssertNil(Pres.rowStatus(other, purgeLease: due, companies: [acme])?.note)
    }

    // MARK: - Banners

    func testSharedGoogleBanner() throws {
        let shared = account(.google, 2, "bob@example.org", shared: true)
        let banner = try XCTUnwrap(Pres.banner(.google, accounts: [shared, account(.google, 3, "x", slug: "acme")]))
        XCTAssertEqual(banner.title, "Gmail is leaving Watchtower's shared Google app")
        XCTAssertEqual(banner.body, "bob@example.org keeps syncing Gmail until Google stops the old sign-in. Move Gmail to "
            + "your company's or your own Google project; Calendar stays on the shared app.")
        XCTAssertEqual(banner.actions, [.useOwnGoogle, .pasteCode])
        XCTAssertEqual(banner.actions.map(\.title), ["Use my own Google project", "Paste a company code"])
        XCTAssertEqual(banner.actions.map(\.isQuiet), [false, true])
        XCTAssertEqual(banner.cardLine, "Gmail on the shared app")
        let two = try XCTUnwrap(Pres.banner(.google, accounts: [shared, account(.google, 4, "carol@example.org", shared: true)]))
        XCTAssertTrue(two.body.hasPrefix("bob@example.org and carol@example.org keep syncing Gmail"))
        // The own-project lock hides its button.
        XCTAssertEqual(Pres.banner(.google, accounts: [shared], locks: [.ownGoogleProject])?.actions, [.pasteCode])
        XCTAssertNil(Pres.banner(.google, accounts: [account(.google, 3, "x")]))
        // An account that no longer syncs does not "keep syncing Gmail".
        XCTAssertNil(Pres.banner(.google, accounts: [account(.google, 5, "y", status: "error", error: "x", shared: true)]))
        let jiraInError = account(.atlassian, 6, "old.atlassian.net", status: "error", error: "unknown_client", shared: true)
        XCTAssertNotNil(Pres.banner(.atlassian, accounts: [jiraInError]))
    }

    func testSharedAtlassianBanner() throws {
        // D15 amended (ask #1600): a Re-login banner, no countdown.
        let shared = account(.atlassian, 1, "old.atlassian.net", shared: true)
        let banner = try XCTUnwrap(Pres.banner(.atlassian, accounts: [shared]))
        XCTAssertEqual(banner.title, "Watchtower's shared Atlassian app is retired")
        XCTAssertEqual(banner.body, "Your company needs its own Atlassian app — ask your admin or set it up. "
            + "Sign old.atlassian.net in again through your company's app or with an API token.")
        XCTAssertFalse(banner.body.contains("days"))
        XCTAssertEqual(banner.actions, [.setUpForCompany, .connectWithToken])
        XCTAssertEqual(banner.actions.map(\.title), ["Set up for my company", "Connect with an API token"])
        XCTAssertEqual(banner.actions.map(\.isQuiet), [false, true])
        XCTAssertEqual(banner.cardLine, "Shared app retired — sign in again")
        let three = try XCTUnwrap(Pres.banner(.atlassian, accounts: [
            shared, account(.atlassian, 2, "b.atlassian.net", shared: true), account(.atlassian, 3, "c.atlassian.net", shared: true)
        ]))
        XCTAssertTrue(three.body.hasSuffix("Sign old.atlassian.net, b.atlassian.net and c.atlassian.net in again "
            + "through your company's app or with an API token."))
        XCTAssertEqual(Pres.banner(.atlassian, accounts: [shared], locks: [.atlassianAPIToken])?.actions, [.setUpForCompany])
        // Only while an account is flagged shared.
        XCTAssertNil(Pres.banner(.atlassian, accounts: [account(.atlassian, 2, "x", authKind: "api_token")]))
        XCTAssertNil(Pres.banner(.slack, accounts: [account(.slack, 1, "x", shared: true)]))
    }

    func testBannersAreNotAttention() {
        // A banner's accounts still sync: their rows keep today's line, no red badge.
        let google = account(.google, 2, "bob@example.org", shared: true)
        let jira = account(.atlassian, 1, "old.atlassian.net", shared: true)
        XCTAssertNotNil(Pres.banner(.google, accounts: [google]))
        XCTAssertNotNil(Pres.banner(.atlassian, accounts: [jira]))
        XCTAssertNil(Pres.rowStatus(google, purgeLease: nil, companies: []))
        XCTAssertNil(Pres.rowStatus(jira, purgeLease: nil, companies: []))
    }

    // MARK: - Locks

    func testOwnGoogleLock() {
        let card = Pres.lockCard(.ownGoogleProject)
        XCTAssertEqual(card.text, "Your organization does not allow own Google projects. Ask IT for your company's link.")
        XCTAssertEqual(card.helpLabel, ManagedPolicyHelp.label)
        XCTAssertEqual(card.helpURL, ManagedPolicyHelp.itGuideURL)
        XCTAssertEqual(AccountGroup.Kind.ownProject.lockKey, .ownGoogleProject)
        XCTAssertNil(AccountGroup.Kind.company("acme").lockKey)
        XCTAssertNil(AccountGroup.Kind.shared.lockKey)
    }

    func testTokenLock() {
        let card = Pres.lockCard(.atlassianAPIToken)
        XCTAssertEqual(card.text, "Your organization does not allow Atlassian API tokens. Token sites stop syncing "
            + "and keep their data.")
        XCTAssertEqual(card.helpLabel, "What IT can set")
        XCTAssertEqual(AccountGroup.Kind.apiTokens.lockKey, .atlassianAPIToken)
    }

    /// The words the mockups show (`Tests/DesignShots/CompanySetupMockCopy.swift`,
    /// which `CompanySetupMockCopyTests.testConnectionsCopyLivesInThePresentation`
    /// holds equal to these).
    func testStringsEqualMockCopy() {
        XCTAssertEqual(Pres.companiesTitle, "Companies")
        XCTAssertEqual(Pres.companiesLoading, "Reading company setups…")
        XCTAssertEqual(Pres.companiesEmpty, "Using Watchtower at work? Connect with your company's link or code, "
            + "or set it up for your company.")
        XCTAssertEqual(Pres.codeInvalid, "That is not a Watchtower company code. Copy it again from the Slack app's About page "
            + "or from your admin.")
        XCTAssertEqual(Pres.groupShared, "Watchtower's shared app")
        XCTAssertEqual(Pres.groupOwnGoogle, "Your own Google project")
        XCTAssertEqual(Pres.groupTokens, "API tokens")
        XCTAssertEqual(Pres.groupUnknown, "Other accounts")
        XCTAssertEqual(Pres.tokenTag, "API token")
        XCTAssertEqual(Pres.sharedTag, "Shared app")
        XCTAssertEqual(Pres.stoppedByPolicyLine, "Stopped by your organization — data kept")
        XCTAssertEqual(Pres.reloginNewLink, "Re-login needed — your company changed its app; open the new link")
        XCTAssertEqual(Pres.reloginUntied, "Re-login needed — open your company's link")
        XCTAssertEqual(Pres.tokenDead, "The API token stopped working (expired or revoked) — paste a new one")
        XCTAssertEqual(Pres.reloginChanged("Acme"), "Re-login needed — Acme changed its app")
    }
}
