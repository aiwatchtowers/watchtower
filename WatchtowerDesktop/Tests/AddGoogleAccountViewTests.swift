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
}
