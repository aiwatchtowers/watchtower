import XCTest
import AppKit
@testable import WatchtowerDesktop

final class ActivationPolicyTests: XCTestCase {
    func testVisibleWindowMeansRegular() {
        XCTAssertEqual(ActivationPolicyDecision.policy(hasVisibleWindow: true), .regular)
    }

    func testNoVisibleWindowMeansAccessory() {
        XCTAssertEqual(ActivationPolicyDecision.policy(hasVisibleWindow: false), .accessory)
    }

    /// The predicate has to hold at `applicationDidFinishLaunching` time, i.e.
    /// before any SwiftUI content mounts and stamps the frame autosave name —
    /// so it keys on the identifier SwiftUI derives from the scene id.
    @MainActor
    func testMainWindowPredicateMatchesSceneIdentifierBeforeMount() {
        let unmounted = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        unmounted.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        XCTAssertEqual(unmounted.frameAutosaveName, "", "precondition: nothing has mounted yet")
        XCTAssertTrue(TrayAppDelegate.isMainWindow(unmounted))
    }

    @MainActor
    func testMainWindowPredicateStillMatchesMountedWindowByAutosaveName() {
        let mounted = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        mounted.setFrameAutosaveName(TrayAppDelegate.mainWindowAutosaveName)
        XCTAssertTrue(TrayAppDelegate.isMainWindow(mounted))
    }

    @MainActor
    func testMainWindowPredicateRejectsSecondaryWindows() {
        let progress = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        progress.identifier = NSUserInterfaceItemIdentifier("progress-detail-AppWindow-1")
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        settings.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        settings.setFrameAutosaveName("Settings")
        XCTAssertFalse(TrayAppDelegate.isMainWindow(progress))
        XCTAssertFalse(TrayAppDelegate.isMainWindow(settings))
    }

    func testMainWindowIdentifierMatching() {
        XCTAssertTrue(TrayAppDelegate.isMainWindowIdentifier("main"))
        XCTAssertTrue(TrayAppDelegate.isMainWindowIdentifier("main-AppWindow-1"))
        XCTAssertFalse(TrayAppDelegate.isMainWindowIdentifier(nil))
        XCTAssertFalse(TrayAppDelegate.isMainWindowIdentifier("progress-detail-AppWindow-1"))
        XCTAssertFalse(TrayAppDelegate.isMainWindowIdentifier("com_apple_SwiftUI_Settings_window"))
        // A different scene whose id merely starts with the same letters.
        XCTAssertFalse(TrayAppDelegate.isMainWindowIdentifier("maintenance-AppWindow-1"))
    }

    /// Stand-in for a window on screen. Nothing here orders a real window front:
    /// putting one on the window server from an xctest process destabilises the
    /// whole test binary (it takes the process down later, in an unrelated
    /// suite), so visibility is stubbed rather than staged.
    private final class StubWindow: NSWindow {
        // Not named `visible`/`main`: those are the ObjC names of the very
        // NSWindow properties being overridden, and a stored property cannot
        // override them.
        private let visibleStub: Bool
        private let mainCapableStub: Bool

        init(visible: Bool, mainCapable: Bool) {
            self.visibleStub = visible
            self.mainCapableStub = mainCapable
            super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        }

        override var isVisible: Bool { visibleStub }
        override var canBecomeMain: Bool { mainCapableStub }
    }

    /// Closing the main window while Settings or Pipeline Progress is open must
    /// keep the app `.regular`: an `.accessory` app with a visible window has
    /// no Dock icon and no menu bar.
    @MainActor
    func testSecondaryWindowAloneStillCountsAsVisible() {
        let settings = StubWindow(visible: true, mainCapable: true)
        XCTAssertTrue(ActivationPolicyDecision.hasVisibleAppWindow([settings]))
        XCTAssertEqual(
            ActivationPolicyDecision.policy(
                hasVisibleWindow: ActivationPolicyDecision.hasVisibleAppWindow([settings])),
            .regular
        )
    }

    @MainActor
    func testHiddenWindowsDoNotCount() {
        XCTAssertFalse(ActivationPolicyDecision.hasVisibleAppWindow([]))
        XCTAssertFalse(
            ActivationPolicyDecision.hasVisibleAppWindow([StubWindow(visible: false, mainCapable: true)]))
    }

    /// The menu-bar extra's status-item window is always visible; counting it
    /// would pin the app to `.regular` forever. Such windows cannot become
    /// main, which is the property the predicate filters on — as a real
    /// non-activating panel confirms.
    @MainActor
    func testVisibleButNonMainCapableWindowDoesNotCount() {
        XCTAssertFalse(
            ActivationPolicyDecision.hasVisibleAppWindow([StubWindow(visible: true, mainCapable: false)]))

        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        XCTAssertFalse(panel.canBecomeMain, "the property the predicate filters on")
    }

    // MARK: - Quit with a popup open (requestQuit's window filter)

    /// Sheet presence is stubbed, not staged — see StubWindow's note on
    /// ordering real windows front from an xctest process.
    private final class SheetedStubWindow: NSWindow {
        private let sheetStub: NSWindow?

        init(sheet: NSWindow?) {
            self.sheetStub = sheet
            super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        }

        override var attachedSheet: NSWindow? { sheetStub }
    }

    /// SwiftUI vetoes app termination while any scene presents a sheet, so
    /// `requestQuit` closes exactly the sheet-carrying windows first — and
    /// must leave every sheetless window for normal termination teardown.
    @MainActor
    func testWindowsBlockingTerminationPicksOnlySheetedWindows() {
        let plain = SheetedStubWindow(sheet: nil)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let sheeted = SheetedStubWindow(sheet: sheet)

        XCTAssertEqual(TrayAppDelegate.windowsBlockingTermination([plain, sheeted]), [sheeted])
        XCTAssertTrue(TrayAppDelegate.windowsBlockingTermination([plain]).isEmpty)
    }
}
