import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// An inspector column opens at the width it was last dragged to (#401).
final class PersistedInspectorWidthTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let range: ClosedRange<Double> = 220...560

    override func setUpWithError() throws {
        suite = "PersistedInspectorWidthTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheColumnOpensAtItsIdealWidthByDefault() {
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 300)
    }

    func testAWidthStoredByAnEarlierRunIsReadAndClamped() {
        defaults.set(410.0, forKey: "w")
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 410)
        defaults.set(2000.0, forKey: "w")
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 560)
        defaults.set(10.0, forKey: "w")
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 220)
    }

    func testOnlyAWidthTheColumnCanBeDraggedToIsStored() {
        XCTAssertNil(PersistedInspectorWidth.widthToStore(0, range: range), "closed")
        XCTAssertNil(PersistedInspectorWidth.widthToStore(120, range: range), "mid-animation")
        XCTAssertEqual(PersistedInspectorWidth.widthToStore(219.6, range: range), 220)
        XCTAssertEqual(PersistedInspectorWidth.widthToStore(412.4, range: range), 412)
        XCTAssertEqual(PersistedInspectorWidth.widthToStore(700, range: range), 560)
    }

    func testASettledWidthIsStoredAndTheNextOpenReadsIt() {
        PersistedInspectorWidth.store(412.4, key: "w", range: range, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "w") as? Double, 412)
        XCTAssertEqual(PersistedInspectorWidth.storedWidth(defaults: defaults, key: "w", range: range, ideal: 300), 412)
        PersistedInspectorWidth.store(700, key: "w", range: range, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "w") as? Double, 560, "clamped to the widest the column gets")
    }

    func testAnAnimationFrameNarrowerThanTheColumnIsNotStored() {
        PersistedInspectorWidth.store(120, key: "w", range: range, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "w"), "nothing stored yet")
        PersistedInspectorWidth.store(410, key: "w", range: range, defaults: defaults)
        PersistedInspectorWidth.store(0, key: "w", range: range, defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: "w") as? Double, 410, "closing keeps the last settled width")
    }

    /// The column has to stay draggable through the range (#735): with the
    /// width probe wrapped around `.inspectorColumnWidth` SwiftUI dropped the
    /// range and pinned the column at its default width.
    @MainActor
    func testTheHostedColumnTakesTheRangeAndKeepsAWidthDraggedTo() throws {
        let key = "w"
        let root = Color.clear
            .inspector(isPresented: .constant(true)) {
                Color.clear.modifier(PersistedInspectorWidth(key: key, range: range, ideal: 300, defaults: defaults))
            }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        defer { window.close() }
        let hosted = window.contentView
        let split = try XCTUnwrap(
            Self.poll { hosted.flatMap(Self.splitView(in:)).flatMap { Self.column(of: $0)?.maximumThickness == 560 ? $0 : nil } },
            "no inspector split with the column range"
        )
        let column = try XCTUnwrap(Self.column(of: split))
        XCTAssertEqual(column.minimumThickness, 220)
        XCTAssertEqual(split.arrangedSubviews.last?.frame.width ?? 0, 300, accuracy: 1, "opens at the ideal")

        split.setPosition(split.frame.width - 500, ofDividerAt: 0)
        let dragged = Self.poll { abs((split.arrangedSubviews.last?.frame.width ?? 0) - 500) <= 1 ? true : nil }
        XCTAssertNotNil(dragged, "dragged wider, got \(split.arrangedSubviews.last?.frame.width ?? 0)")
        let stored = Self.poll(timeout: 3) { (defaults.object(forKey: key) as? Double).flatMap { abs($0 - 500) <= 1 ? $0 : nil } }
        XCTAssertNotNil(stored, "the settled width is stored, got \(String(describing: defaults.object(forKey: key)))")
    }

    /// Spins the main run loop until `probe` yields a value or `timeout` runs out.
    @MainActor
    private static func poll<T>(timeout: TimeInterval = 2, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probe() { return value }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return probe()
    }

    private static func column(of split: NSSplitView) -> NSSplitViewItem? {
        (split.delegate as? NSSplitViewController)?.splitViewItems.last
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }
}
