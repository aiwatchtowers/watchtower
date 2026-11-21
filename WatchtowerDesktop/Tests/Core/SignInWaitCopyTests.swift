import XCTest
@testable import WatchtowerCore

/// The waiting browser sign-in's texts (#2132, spec "The waiting line"):
/// one copy for every connector.
final class SignInWaitCopyTests: XCTestCase {
    func testEveryServiceNamesItselfInTheLine() {
        let cases: [(SignInWaitCopy, String)] = [
            (.google, "Waiting for the Google sign-in in your browser…"),
            (.slack, "Waiting for the Slack sign-in in your browser…"),
            (.atlassian, "Waiting for the Atlassian sign-in in your browser…"),
            (.linear, "Waiting for the Linear sign-in in your browser…"),
            (.microsoft, "Waiting for the Microsoft sign-in in your browser…"),
            (SignInWaitCopy(service: "Acme Docs"), "Waiting for the Acme Docs sign-in in your browser…")
        ]
        for (copy, line) in cases {
            XCTAssertEqual(copy.line, line)
            XCTAssertEqual(copy.hint, "If the page shows an error or you closed it, press Cancel.")
            XCTAssertEqual(copy.cancelTitle, "Cancel")
        }
    }
}
