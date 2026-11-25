import XCTest
import AppKit
@testable import WatchtowerDesktop

/// The update button shows a Software Update window that already exists:
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

    func testMinimizedWindowIsMovedAndRestoredBeforeActivationThenFronted() {
        var log: [String] = []
        let update = RecordingWindow(identifier: "update-available-AppWindow-1", state: .minimized) { log.append($0) }
        let other = RecordingWindow(identifier: "main", state: .minimized) { log.append("other " + $0) }

        let shown = UpdateAvailableView.present(
            windows: [other, update],
            activate: { log.append("activate") },
            open: { log.append("open") }
        )

        XCTAssertTrue(shown)
        XCTAssertEqual(log, ["deminiaturize moveToActiveSpace", "front moveToActiveSpace", "activate", "front moveToActiveSpace"],
                       "the window is on the active Space before the app activates; no new window is opened")
        XCTAssertFalse(other.collectionBehavior.contains(.moveToActiveSpace), "other windows are left alone")
    }

    func testWindowOnAnotherSpaceIsFrontedWithoutDeminiaturizing() {
        var log: [String] = []
        let update = RecordingWindow(identifier: "update-available", state: .visible) { log.append($0) }

        _ = UpdateAvailableView.present(windows: [update], activate: { log.append("activate") }, open: { log.append("open") })

        XCTAssertEqual(log, ["front moveToActiveSpace", "activate", "front moveToActiveSpace"],
                       "ordered in on the active Space before activation, so activation does not switch Spaces")
    }

    func testNoWindowYetIsOpened() {
        var log: [String] = []
        let other = RecordingWindow(identifier: "main", state: .visible) { log.append("other " + $0) }

        _ = UpdateAvailableView.present(windows: [other], activate: { log.append("activate") }, open: { log.append("open") })

        XCTAssertEqual(log, ["activate", "open"])
    }

    func testClosedWindowStillHeldIsReopenedNotFronted() {
        var log: [String] = []
        let closed = RecordingWindow(identifier: "update-available", state: .closed) { log.append($0) }

        _ = UpdateAvailableView.present(windows: [closed], activate: { log.append("activate") }, open: { log.append("open") })

        XCTAssertEqual(log, ["activate", "open"])
    }
}

/// Records restoring and fronting (with whether it was on the active Space
/// by then), without a real window server.
private final class RecordingWindow: NSWindow {
    enum State { case visible, minimized, closed }

    private let state: State
    private let record: (String) -> Void

    init(identifier: String, state: State, record: @escaping (String) -> Void) {
        self.state = state
        self.record = record
        super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isReleasedWhenClosed = false
    }

    private var spaceNote: String {
        collectionBehavior.contains(.moveToActiveSpace) ? "moveToActiveSpace" : "staysOnItsSpace"
    }

    override var isVisible: Bool { state == .visible }
    override var isMiniaturized: Bool { state == .minimized }
    override func deminiaturize(_ sender: Any?) { record("deminiaturize \(spaceNote)") }
    override func makeKeyAndOrderFront(_ sender: Any?) { record("front \(spaceNote)") }
}
