import XCTest
@testable import WatchtowerCore

final class TerminalSessionNamingTests: XCTestCase {
    func testProvisionalUsesTheInjectedClock() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 9 * 3600 + 5 * 60)
        XCTAssertEqual(TerminalSessionNaming.provisional(now: now, calendar: cal), "New session · 09:05")
    }

    func testShellNameUsesLastPathComponents() {
        XCTAssertEqual(TerminalSessionNaming.shell(shellPath: "/opt/homebrew/bin/fish", folder: "/Users/x/acme"), "fish — acme")
        XCTAssertEqual(TerminalSessionNaming.shell(shellPath: nil, folder: "/Users/x/acme"), "zsh — acme")
    }

    func testSetupTitle() {
        XCTAssertEqual(TerminalSessionNaming.setupTitle, "Project setup")
    }
}
