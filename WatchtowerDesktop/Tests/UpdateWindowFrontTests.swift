import XCTest
import AppKit
@testable import WatchtowerDesktop

/// The update button fronts a Software Update window that already exists:
/// `openWindow` alone left a minimized window, or one on another Space,
/// out of sight, so the click looked dead.
@MainActor
final class UpdateWindowFrontTests: XCTestCase {
    func testIdentifierMatchesTheSceneAndItsVariants() {
        XCTAssertTrue(UpdateAvailableView.isWindowIdentifier("update-available"))
        XCTAssertTrue(UpdateAvailableView.isWindowIdentifier("update-available-AppWindow-1"))
        XCTAssertFalse(UpdateAvailableView.isWindowIdentifier("update-availableX"))
        XCTAssertFalse(UpdateAvailableView.isWindowIdentifier("main"))
        XCTAssertFalse(UpdateAvailableView.isWindowIdentifier(nil))
    }

    func testMinimizedUpdateWindowIsRestoredMovedToTheActiveSpaceAndFronted() {
        let update = RecordingWindow(identifier: "update-available-AppWindow-1", miniaturized: true)
        let other = RecordingWindow(identifier: "main", miniaturized: true)

        UpdateAvailableView.frontExistingWindow(in: [other, update])

        XCTAssertEqual(update.deminiaturized, 1)
        XCTAssertEqual(update.fronted, 1)
        XCTAssertTrue(update.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertEqual(other.deminiaturized, 0, "other windows are left alone")
        XCTAssertEqual(other.fronted, 0)
        XCTAssertFalse(other.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testWindowOnAnotherSpaceIsFrontedWithoutDeminiaturizing() {
        let update = RecordingWindow(identifier: "update-available", miniaturized: false)

        UpdateAvailableView.frontExistingWindow(in: [update])

        XCTAssertEqual(update.deminiaturized, 0)
        XCTAssertEqual(update.fronted, 1)
        XCTAssertTrue(update.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testNoUpdateWindowYetDoesNothing() {
        let other = RecordingWindow(identifier: "main", miniaturized: false)
        UpdateAvailableView.frontExistingWindow(in: [other])
        XCTAssertEqual(other.fronted, 0, "a window still to be created is openWindow's job")
    }
}

/// Records restoring and fronting, without a real window server.
private final class RecordingWindow: NSWindow {
    private let startsMinimized: Bool
    private(set) var deminiaturized = 0
    private(set) var fronted = 0

    init(identifier: String, miniaturized: Bool) {
        self.startsMinimized = miniaturized
        super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isReleasedWhenClosed = false
    }

    override var isMiniaturized: Bool { startsMinimized }
    override func deminiaturize(_ sender: Any?) { deminiaturized += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { fronted += 1 }
}
