import AppKit
import XCTest
@testable import WatchtowerDesktop

/// The sessions panel's swipe back to the workbench list (board #743): which
/// gestures count, and the monitor's lifetime.
@MainActor
final class WorkbenchBackSwipeTests: XCTestCase {
    func testAThreeFingerSwipeRightGoesBack() {
        XCTAssertTrue(WorkbenchBackSwipeCatcher.isBackSwipe(deltaX: 1, deltaY: 0))
        XCTAssertFalse(WorkbenchBackSwipeCatcher.isBackSwipe(deltaX: -1, deltaY: 0), "left is forward: nothing")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.isBackSwipe(deltaX: 0, deltaY: 1), "up or down: nothing")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.isBackSwipe(deltaX: 0, deltaY: 0), "no movement: nothing")
    }

    func testOnlyASidewaysScrollStartTracksASwipe() {
        XCTAssertTrue(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: 4, deltaY: 1, trackingEnabled: true
        ))
        XCTAssertTrue(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: -4, deltaY: 1, trackingEnabled: true
        ), "the direction is decided while tracking, not by the first event")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: 4, deltaY: 1, trackingEnabled: false
        ), "swipe between pages off in System Settings")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .changed, deltaX: 4, deltaY: 1, trackingEnabled: true
        ), "the middle of a scroll")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: 1, deltaY: 4, trackingEnabled: true
        ), "a vertical scroll stays the list's")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: 3, deltaY: 2, trackingEnabled: true
        ), "a scroll that merely leans sideways stays the list's")
        XCTAssertTrue(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: 4, deltaY: 2, trackingEnabled: true
        ), "twice as sideways: the boundary counts")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: .began, deltaX: 0, deltaY: 0, trackingEnabled: true
        ))
        XCTAssertFalse(WorkbenchBackSwipeCatcher.startsTrackedSwipe(
            phase: [], deltaX: 4, deltaY: 0, trackingEnabled: true
        ), "a mouse wheel has no phase")
    }

    func testATrackedSwipeGoesBackOnlyWhenItEndsOnTheBackSide() {
        XCTAssertTrue(WorkbenchBackSwipeCatcher.trackedSwipeGoesBack(amount: 1, phase: .ended))
        XCTAssertFalse(WorkbenchBackSwipeCatcher.trackedSwipeGoesBack(amount: 0.4, phase: .cancelled),
                       "let go short of the threshold")
        XCTAssertFalse(WorkbenchBackSwipeCatcher.trackedSwipeGoesBack(amount: 0.6, phase: .changed))
        XCTAssertFalse(WorkbenchBackSwipeCatcher.trackedSwipeGoesBack(amount: 0, phase: .ended))
    }

    func testTheMonitorLivesWhileTheViewIsInAWindow() {
        let view = WorkbenchBackSwipeCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertFalse(view.isWatchingSwipes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isWatchingSwipes)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "clicks fall through to the panel")
        view.removeFromSuperview()
        XCTAssertFalse(view.isWatchingSwipes)
    }

    func testOnlyAnEventOverThePanelInItsWindowWithNoSheetCounts() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WorkbenchBackSwipeCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(view)
        defer {
            view.removeFromSuperview()
            window.close()
        }
        func event(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        XCTAssertTrue(view.isOverPanel(try event(at: NSPoint(x: 50, y: 50), in: window)))
        XCTAssertFalse(view.isOverPanel(try event(at: NSPoint(x: 300, y: 50), in: window)), "over the page")

        let other = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertFalse(view.isOverPanel(try event(at: NSPoint(x: 50, y: 50), in: other)), "another window")

        view.isEnabled = false
        XCTAssertFalse(view.isOverPanel(try event(at: NSPoint(x: 50, y: 50), in: window)), "the Go to… palette is up")
        view.isEnabled = true

        view.hasSheet = { _ in true }
        XCTAssertFalse(view.isOverPanel(try event(at: NSPoint(x: 50, y: 50), in: window)), "a sheet is up")
    }
}
