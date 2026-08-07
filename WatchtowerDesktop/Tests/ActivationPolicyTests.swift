import XCTest
import AppKit
@testable import WatchtowerDesktop

final class ActivationPolicyTests: XCTestCase {
    func testMainWindowVisibleMeansRegular() {
        XCTAssertEqual(ActivationPolicyDecision.policy(hasVisibleMainWindow: true), .regular)
    }

    func testNoMainWindowMeansAccessory() {
        XCTAssertEqual(ActivationPolicyDecision.policy(hasVisibleMainWindow: false), .accessory)
    }

    @MainActor
    func testMainWindowPredicateKeysOnAutosaveName() {
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        main.setFrameAutosaveName("WatchtowerMainWindow")
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.setFrameAutosaveName("Settings")
        XCTAssertTrue(TrayAppDelegate.isMainWindow(main))
        XCTAssertFalse(TrayAppDelegate.isMainWindow(other))
    }
}
