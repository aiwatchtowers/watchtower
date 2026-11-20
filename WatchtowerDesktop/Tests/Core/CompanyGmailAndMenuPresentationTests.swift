import Foundation
@testable import WatchtowerCore
import XCTest

/// The Connect… menu's company entries (company screens spec §2.1) and the
/// way Gmail connects now that Watchtower's shared Google app asks for
/// Calendar only (parent D11, #1887 T19): the shared sheet's Gmail switch,
/// and where Email → Add Account → Connect Gmail goes.
final class CompanyGmailAndMenuPresentationTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    private let acme = CompanyRef(slug: "acme", name: "Acme", vendors: [.google: "example.com"])
    private let slackOnly = CompanyRef(slug: "beta", name: "Beta", vendors: [.slack: "A0BETA"])
    private let own = CompanyRef(slug: "me", name: "Me", personal: true, vendors: [.google: ""])

    func testConnectMenuEndsWithTheCompanyEntries() {
        XCTAssertEqual(Pres.connectMenuCompanyActions, [.setUpForCompany, .connectWithCode])
        XCTAssertEqual(Pres.connectMenuCompanyActions.map(\.title), ["Set up for my company", "Connect with a company code"])
    }

    /// Go's `googleOnSharedClient`: only the public (flavorless) build's baked
    /// client is the shared app; a flavored build bakes its company's app (or
    /// a developer's), which may ask for Gmail.
    func testSharedSheetOffersGmailOnlyOnAFlavoredBuild() {
        XCTAssertFalse(Pres.sharedGoogleOffersGmail(buildFlavor: ""))
        XCTAssertTrue(Pres.sharedGoogleOffersGmail(buildFlavor: "corp"))
        XCTAssertTrue(Pres.sharedGoogleOffersGmail(buildFlavor: "dev"))
    }

    func testSharedSheetGmailNote() {
        XCTAssertEqual(Pres.sharedGoogleGmailNote(locks: []),
                       "Watchtower's shared Google app connects Calendar only. Gmail needs a Google project: your "
                           + "company's (ask your admin for the link) or your own. Connect it in Connections → Google.")
        // §5.4: with own projects locked only the company's project remains.
        XCTAssertEqual(Pres.sharedGoogleGmailNote(locks: [.ownGoogleProject]),
                       "Watchtower's shared Google app connects Calendar only. Gmail needs your company's Google "
                           + "project: ask your admin for the link.")
    }

    func testSheetAndCardTexts() {
        XCTAssertEqual(Pres.connectGmail, "Connect Gmail")
        XCTAssertEqual(AddGoogleAccountCopy.title, "Add Google Account")
        XCTAssertEqual([AddGoogleAccountCopy.calendar, AddGoogleAccountCopy.gmail], ["Calendar", "Gmail"])
        XCTAssertEqual([AddGoogleAccountCopy.connect, AddGoogleAccountCopy.connecting, AddGoogleAccountCopy.cancel,
                        AddGoogleAccountCopy.close], ["Connect", "Connecting…", "Cancel", "Close"])
    }

    func testGmailCardLine() {
        XCTAssertEqual(Pres.gmailCardLine(offersGmail: true, locks: []),
                       "Google's OAuth flow — supports multiple Google accounts.")
        XCTAssertEqual(Pres.gmailCardLine(offersGmail: false, locks: []),
                       "Gmail needs a Google project: your company's or your own. Connect opens Connections → Google.")
        XCTAssertEqual(Pres.gmailCardLine(offersGmail: false, locks: [.ownGoogleProject]),
                       "Gmail needs your company's Google project. Connect opens Connections → Google.")
    }

    private func route(
        _ companies: [CompanyRef],
        known: Bool = true,
        googleAllowed: Bool = true,
        locks: Set<LockKey> = []
    ) -> GmailRoute {
        Pres.gmailRoute(companies: companies, companiesKnown: known, googleAllowed: googleAllowed, locks: locks)
    }

    func testGmailRoute() {
        // No company Google app: the own Google project page (T26).
        XCTAssertEqual(route([]), .ownProjectPage)
        XCTAssertEqual(route([slackOnly, own]), .ownProjectPage)
        // A stored company with a Google app: its row in the Google detail (§5.3).
        XCTAssertEqual(route([slackOnly, acme]), .googleDetail)
        // Own projects locked (§5.4): the detail, whose empty state offers the company code.
        XCTAssertEqual(route([], locks: [.ownGoogleProject]), .googleDetail)
        // Company files unread or failed to read: the detail, never a guess.
        XCTAssertEqual(route([], known: false), .googleDetail)
        // The organization blocks Google: the detail with its blocked buttons, never the page.
        XCTAssertEqual(route([], googleAllowed: false), .googleDetail)
    }

    func testOnboardingGoogleSubtitle() {
        XCTAssertEqual(Pres.onboardingGoogleSubtitle(offersGmail: true),
                       "Mail and calendar · for work communication and meetings")
        XCTAssertEqual(Pres.onboardingGoogleSubtitle(offersGmail: false),
                       "Calendar · for meetings; Gmail connects later in Connections")
    }
}
