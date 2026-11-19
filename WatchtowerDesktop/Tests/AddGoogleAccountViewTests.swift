import GRDB
import SwiftUI
import ViewInspector
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Add Google Account without "Advanced: custom OAuth client" (#1887 C4,
/// S19): an own project is the Google detail's page now.
@MainActor
final class AddGoogleAccountViewTests: XCTestCase {
    func testNoCustomClientDisclosure() throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.googleAccountsViewModel = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { nil }
        let view = AddGoogleAccountView().environment(appState)

        XCTAssertThrowsError(try view.inspect().find(text: "Advanced: custom OAuth client"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.SecureField.self), "no client secret field")
        XCTAssertThrowsError(try view.inspect().find(ViewType.TextField.self), "no client id field")
        XCTAssertFalse(try view.inspect().find(button: "Connect").isDisabled())
    }

    /// The shared app asks for Calendar only (#1887 D11): Gmail is shown off
    /// and disabled, the note says where it connects, and Connect asks for
    /// Calendar alone.
    func testSharedPathGmailOffWithNote() throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let view = AddGoogleAccountView(offersGmail: false).environment(appState)

        let gmail = try view.inspect().find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Gmail" }
        XCTAssertTrue(gmail.isDisabled())
        XCTAssertFalse(try gmail.isOn())
        XCTAssertNoThrow(try view.inspect().find(text: CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: [])))
        XCTAssertFalse(try view.inspect().find(button: "Connect").isDisabled(), "Calendar alone still connects")
    }

    /// Own projects locked (§5.4): the note names the company's project only.
    func testSharedPathNoteUnderOwnProjectLock() throws {
        let (appState, _) = LinearConnectionDetailTests.wired(policy: ["AllowOwnGoogleProject": false])
        let view = AddGoogleAccountView(offersGmail: false).environment(appState)
        XCTAssertNoThrow(try view.inspect().find(
            text: CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: [.ownGoogleProject])))
    }

    /// A flavored build's client asks for Gmail: the switch is live and on, no note.
    func testFlavoredBuildOffersGmail() throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let view = AddGoogleAccountView(offersGmail: true).environment(appState)

        let gmail = try view.inspect().find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Gmail" }
        XCTAssertFalse(gmail.isDisabled())
        XCTAssertTrue(try gmail.isOn())
        XCTAssertThrowsError(try view.inspect().find(text: CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: [])))
    }
}
