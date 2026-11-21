import DesignKit
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// **Use my own Google project** while its sign-in waits (#2132 G5): the
/// page shows the shared waiting line, and its Cancel takes the page back
/// to the form.
@MainActor
final class OwnGoogleProjectPageTests: XCTestCase {
    private static let clientJSON = Data(#"""
    {"installed":{"client_id":"5678-own.apps.googleusercontent.com","client_secret":"own-secret","project_id":"acme"}}
    """#.utf8)

    func testWaitingLineWhileChecking() async throws {
        let cli = FakeCLILineStream()
        let model = OwnGoogleProjectModel { cli }
        model.open()
        XCTAssertTrue(model.drop(Self.clientJSON, fileName: "client_secret_5678-own.json"))
        let page = OwnGoogleProjectPage(model: model)
        XCTAssertThrowsError(try page.inspect().find(SignInWaitLine.self), "no waiting line before Connect")

        let run = Task { await model.connect() }
        let session = await cli.session(number: 1)
        let copy = SignInWaitCopy.google
        XCTAssertNoThrow(try page.inspect().find(SignInWaitLine.self))
        XCTAssertNoThrow(try page.inspect().find(text: copy.line))
        XCTAssertNoThrow(try page.inspect().find(text: copy.hint))

        try page.inspect().find(button: copy.cancelTitle).tap()
        session.exit(code: 1) // the killed CLI ends
        await run.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertThrowsError(try page.inspect().find(SignInWaitLine.self), "Cancel takes the page back to the form")
        XCTAssertNoThrow(try page.inspect().find(text: OwnGoogleProjectModel.unverifiedNote))
    }
}
