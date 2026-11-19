import Foundation
@testable import WatchtowerCore
import XCTest

/// Company screens spec §4.2 (loading / read failed), §5.3 and §6.4 (the
/// empty states), the add sections, and the shared-app flags the Google and
/// Jira details read from Go (#1887 Task 25b).
final class CompanyDetailPresentationTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    private let acme = CompanyRef(slug: "acme", name: "Acme", vendors: [
        .google: "example.com", .atlassian: "https://acme.atlassian.net"
    ])
    private let beta = CompanyRef(slug: "beta", name: "Beta", vendors: [.atlassian: "https://beta.atlassian.net"])

    private func account(_ vendor: CompanyVendor, slug: String = "", shared: Bool = false) -> AccountRef {
        AccountRef(vendor: vendor, accountID: 1, label: "alice@example.com", companySlug: slug, status: "ok", error: "",
                   sharedApp: shared)
    }

    private func groups(_ vendor: CompanyVendor, _ accounts: [AccountRef], _ companies: [CompanyRef]) -> [AccountGroup] {
        Pres.groups(vendor: vendor, accounts: accounts, companies: companies) { _ in false }
    }

    // MARK: - List state

    func testLoadingBeforeTheFirstRead() {
        XCTAssertEqual(Pres.accountsList(vendor: .google, loaded: false, readError: nil, accounts: [], groups: []),
                       .loading("Reading Google accounts…"))
        XCTAssertEqual(Pres.accountsList(vendor: .atlassian, loaded: false, readError: nil, accounts: [], groups: []),
                       .loading("Reading Jira sites…"))
    }

    /// A failed read with nothing listed is its own state, even when a stored
    /// company would add a Not connected row: nobody knows what is connected.
    func testReadFailedIsNotEmpty() {
        let notConnected = groups(.google, [], [acme])
        XCTAssertFalse(notConnected.isEmpty)
        XCTAssertEqual(Pres.accountsList(vendor: .google, loaded: true, readError: "database is locked", accounts: [],
                                         groups: notConnected),
                       .readFailed("Could not read Google accounts: database is locked."))
        XCTAssertEqual(Pres.accountsList(vendor: .atlassian, loaded: true, readError: "database is locked.", accounts: [],
                                         groups: []),
                       .readFailed("Could not read Jira sites: database is locked."))
        // Accounts read before stay listed when a later read fails.
        let listed = groups(.google, [account(.google)], [])
        XCTAssertEqual(Pres.accountsList(vendor: .google, loaded: true, readError: "x", accounts: [account(.google)],
                                         groups: listed), .groups(listed))
    }

    func testEmptyOnlyWithoutAnyGroup() {
        XCTAssertEqual(Pres.accountsList(vendor: .google, loaded: true, readError: nil, accounts: [], groups: []),
                       .empty(Pres.googleEmpty))
        XCTAssertEqual(Pres.accountsList(vendor: .atlassian, loaded: true, readError: nil, accounts: [], groups: []),
                       .empty(Pres.jiraEmpty))
        // §5.3: a company with a Google block shows its Not connected row instead.
        let company = groups(.google, [], [acme])
        XCTAssertEqual(Pres.accountsList(vendor: .google, loaded: true, readError: nil, accounts: [], groups: company),
                       .groups(company))
    }

    // MARK: - Actions

    func testGoogleActions() {
        let empty = Pres.detailActions(.google, companies: [], empty: true)
        XCTAssertEqual(empty.map(\.title), ["Connect Google Calendar", "Use my own Google project", "Paste a company code"])
        XCTAssertEqual(empty.map(\.emphasis), [.prominent, .secondary, .quiet])
        let add = Pres.detailActions(.google, companies: [acme], empty: false)
        XCTAssertEqual(add.map(\.kind), [.connectCalendar, .useOwnGoogle, .pasteCode])
        XCTAssertEqual(add.map(\.emphasis), [.secondary, .secondary, .quiet])
        // §5.4: the lock removes the own project everywhere.
        let locked = Pres.detailActions(.google, companies: [], empty: false, locks: [.ownGoogleProject])
        XCTAssertEqual(locked.map(\.kind), [.connectCalendar, .pasteCode])
    }

    func testJiraActions() {
        let empty = Pres.detailActions(.atlassian, companies: [], empty: true)
        XCTAssertEqual(empty.map(\.title), ["Connect with an API token", "Paste a company code"])
        XCTAssertEqual(empty.map(\.emphasis), [.prominent, .quiet])
        let add = Pres.detailActions(.atlassian, companies: [beta, acme], empty: false)
        XCTAssertEqual(add.map(\.title), ["Connect with Acme's Atlassian app", "Connect with Beta's Atlassian app",
                                          "Connect with an API token"])
        XCTAssertEqual(add.map(\.kind), [.connectCompany(slug: "acme"), .connectCompany(slug: "beta"), .connectWithToken])
        // A company without an Atlassian app, or a personal bundle, offers none.
        let google = CompanyRef(slug: "g", name: "G", vendors: [.google: ""])
        let personal = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.atlassian: ""])
        XCTAssertEqual(Pres.detailActions(.atlassian, companies: [google, personal], empty: false).map(\.kind),
                       [.connectWithToken, .pasteCode])
        // §6.5: the lock removes the token.
        XCTAssertEqual(Pres.detailActions(.atlassian, companies: [acme], empty: false, locks: [.atlassianAPIToken])
            .map(\.kind), [.connectCompany(slug: "acme")])
        XCTAssertEqual(Pres.detailActions(.atlassian, companies: [], empty: true, locks: [.atlassianAPIToken]).map(\.kind),
                       [.pasteCode])
    }

    func testLocksFromPolicy() {
        XCTAssertEqual(Pres.locks(ownGoogleProjectAllowed: true, atlassianAPITokenAllowed: true), [])
        XCTAssertEqual(Pres.locks(ownGoogleProjectAllowed: false, atlassianAPITokenAllowed: false),
                       [.ownGoogleProject, .atlassianAPIToken])
    }

    // MARK: - Row lines

    func testRowLines() {
        XCTAssertEqual(Pres.googleRowLine(account(.google), calendar: true, gmail: true), "Syncing · Calendar and Gmail")
        XCTAssertEqual(Pres.googleRowLine(account(.google, shared: true), calendar: false, gmail: true),
                       "Syncing through the shared app · Gmail")
        XCTAssertEqual(Pres.googleRowLine(account(.google), calendar: true, gmail: false), "Syncing · Calendar")
        let site = AccountRef(vendor: .atlassian, accountID: 1, label: "acme.atlassian.net", companySlug: "", status: "ok",
                              error: "")
        XCTAssertEqual(Pres.jiraRowLine(site, title: "acme.atlassian.net", enabled: true, email: "alice@example.com"),
                       "Syncing · alice@example.com")
        // A renamed site keeps its address on the line.
        XCTAssertEqual(Pres.jiraRowLine(site, title: "Work", enabled: true, email: ""), "Syncing · acme.atlassian.net")
        XCTAssertEqual(Pres.jiraRowLine(site, title: "acme.atlassian.net", enabled: false, email: ""), "Turned off")
    }

    /// Only a healthy row claims to sync; revoked, failed and purged rows do not.
    func testRowLineNeverClaimsSyncingOnABrokenRow() {
        func ref(_ status: String) -> AccountRef {
            AccountRef(vendor: .google, accountID: 1, label: "a", companySlug: "", status: status, error: "token expired")
        }
        XCTAssertEqual(Pres.googleRowLine(ref("revoked"), calendar: true, gmail: false), "Not syncing · Calendar")
        XCTAssertEqual(Pres.googleRowLine(ref("error"), calendar: true, gmail: false), "Not syncing · Calendar")
        XCTAssertEqual(Pres.googleRowLine(ref("purged"), calendar: true, gmail: false), "Data deleted · Calendar")
    }

    /// Without the API token on offer (its lock, or a build without the sheet)
    /// no text points at it.
    func testNoTokenOfferNoTokenText() {
        XCTAssertEqual(Pres.accountsList(vendor: .atlassian, loaded: true, readError: nil, accounts: [], groups: [],
                                         locks: [.atlassianAPIToken]),
                       .empty("Your company has no Atlassian app in Watchtower yet. Ask your admin for the company link."))
        let shared = account(.atlassian, shared: true)
        let banner = Pres.banner(.atlassian, accounts: [shared], locks: [.atlassianAPIToken])
        XCTAssertEqual(banner?.body, "Your company needs its own Atlassian app — ask your admin or set it up. "
            + "Sign alice@example.com in again through your company's app.")
        XCTAssertEqual(banner?.actions, [.setUpForCompany])
    }

    // MARK: - Shared-app flags from Go

    func testSharedFlagsReadByID() throws {
        let google = #"[{"id":1,"shared_gmail":true},{"id":2,"shared_gmail":false},{"id":3}]"#
        XCTAssertEqual(try SharedAppFlags.accountIDs(Data(google.utf8), flag: SharedAppFlags.googleFlag), [1])
        let jira = #"[{"id":4,"auth_kind":"oauth","shared_atlassian":true},{"id":5,"shared_atlassian":false}]"#
        XCTAssertEqual(try SharedAppFlags.accountIDs(Data(jira.utf8), flag: SharedAppFlags.jiraFlag), [4])
        XCTAssertEqual(try SharedAppFlags.accountIDs(Data("[]".utf8), flag: SharedAppFlags.jiraFlag), [])
    }

    /// Anything but an array of rows with ids is a failed read, never "none shared".
    func testSharedFlagsRejectOtherShapes() {
        for text in ["", "{}", #"{"accounts":[]}"#, #"[{"shared_gmail":true}]"#, "nope"] {
            XCTAssertThrowsError(try SharedAppFlags.accountIDs(Data(text.utf8), flag: SharedAppFlags.googleFlag), text)
        }
    }

    /// One read gives every asked flag, each with its own ids (#1887 C4).
    func testOwnProjectFlagReadWithSharedFlag() throws {
        let google = #"[{"id":1,"shared_gmail":true,"own_project":false},{"id":2,"own_project":true},{"id":3}]"#
        let flags = try SharedAppFlags.accountIDs(Data(google.utf8),
                                                  flags: [SharedAppFlags.googleFlag, SharedAppFlags.ownProjectFlag])
        XCTAssertEqual(flags, ["shared_gmail": [1], "own_project": [2]])
    }

    // MARK: - Own Google project (#1887 C4)

    /// Go's own-project rule reaches the groups: an untied account flagged
    /// `own_project` (a legacy credentials file) lands in "Your own Google
    /// project", not under the shared app; a personal bundle's account too.
    func testUntiedOwnProjectGroupsAsOwn() {
        let legacy = AccountRef(vendor: .google, accountID: 7, label: "alice@example.net", companySlug: "",
                                status: "ok", error: "")
        let personal = CompanyRef(slug: "bob-example-org", name: "bob@example.org", personal: true, vendors: [:])
        let tied = AccountRef(vendor: .google, accountID: 8, label: "bob@example.org", companySlug: "bob-example-org",
                              status: "ok", error: "")
        let own = { (a: AccountRef) in a.accountID == 7 }
        let groups = Pres.groups(vendor: .google, accounts: [legacy, tied], companies: [personal], ownProject: own)
        XCTAssertEqual(groups.map(\.kind), [.ownProject])
        XCTAssertEqual(groups.first?.rows, [.account(legacy), .account(tied)])
        XCTAssertTrue(Pres.isOwnGoogleProject(legacy, companies: [], ownProject: own))
        XCTAssertTrue(Pres.isOwnGoogleProject(tied, companies: [personal]) { _ in false })
        XCTAssertFalse(Pres.isOwnGoogleProject(legacy, companies: []) { _ in false }, "unflagged: the shared app's")
        XCTAssertFalse(Pres.isOwnGoogleProject(account(.atlassian), companies: []) { _ in true })
    }

    /// D11: a shared-app Gmail row that must sign in again offers the move,
    /// not a Re-login the shared app would refuse; under the §5.4 lock a
    /// company code instead.
    func testSharedGmailRowOffersTheMove() {
        func row(_ status: String, shared: Bool = true) -> AccountRef {
            AccountRef(vendor: .google, accountID: 2, label: "carol@example.com", companySlug: "", status: status,
                       error: "", sharedApp: shared)
        }
        XCTAssertEqual(Pres.sharedGmailMove(row("error"), locks: []), .useOwnGoogle)
        XCTAssertEqual(Pres.sharedGmailMove(row("revoked"), locks: [.ownGoogleProject]), .pasteCode)
        XCTAssertNil(Pres.sharedGmailMove(row("ok"), locks: []), "a syncing row needs no move (the banner offers it)")
        XCTAssertNil(Pres.sharedGmailMove(row("error", shared: false), locks: []), "its own Re-login works")
        XCTAssertNil(Pres.sharedGmailMove(row("removed"), locks: []))
    }

    /// `jira accounts --json`'s lease day (§6.3): present only on the rows Go
    /// set it on; an unreadable date is a failed read, never "no lease".
    func testLeaseDatesReadByID() throws {
        let rows = #"[{"id":4,"purge_lease_at":"2026-12-18T09:00:00Z"},{"id":5,"purge_lease_at":""},{"id":6}]"#
        let dates = try SharedAppFlags.dates(Data(rows.utf8), field: SharedAppFlags.jiraLeaseField)
        XCTAssertEqual(dates, [4: Date(timeIntervalSince1970: 1_797_584_400)])
        XCTAssertThrowsError(try SharedAppFlags.dates(Data(#"[{"id":4,"purge_lease_at":"soon"}]"#.utf8),
                                                      field: SharedAppFlags.jiraLeaseField))
    }
}
