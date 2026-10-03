import AppKit
import SwiftUI
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Where SwiftUI puts the Files pane's `.inspector` inside the workbench's
/// own split (`WorkspaceSplitView`, an HStack, no NavigationSplitView): it
/// must stay inside the Files pane, on its right, and leave the other pane
/// alone.
@MainActor
final class CodeInspectorPlacementTests: XCTestCase {
    func testTheInspectorStaysInsideTheFilesPaneOfASplit() async throws {
        let frames = FrameProbe()
        let root = WorkspaceSplitView(
            panes: [.board, .files], expanded: nil, fraction: 0.5, onCommit: { _ in },
            pane: { pane in
                Group {
                    if pane == .files {
                        Color.blue
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frames.files = $0 })
                            .inspector(isPresented: .constant(true)) {
                                Color.green
                                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frames.inspector = $0 })
                                    .inspectorColumnWidth(min: 220, ideal: 300, max: 560)
                            }
                    } else {
                        Color.red
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { frames.other = $0 })
                    }
                }
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        defer { window.close() }
        for _ in 0..<20 where frames.inspector == nil {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let inspector = try XCTUnwrap(frames.inspector, "the inspector was laid out")
        let files = try XCTUnwrap(frames.files)
        let other = try XCTUnwrap(frames.other)
        XCTAssertGreaterThanOrEqual(inspector.minX, other.maxX, "the inspector is not over the other pane")
        XCTAssertGreaterThanOrEqual(inspector.minX, files.maxX - 0.5, "the inspector is right of the Files content")
        XCTAssertLessThanOrEqual(inspector.maxX, 1200.5, "inside the window")
        XCTAssertEqual(other.width, 1200 * 0.5 - 3.5, accuracy: 4, "the other pane keeps its width")
    }
}

@MainActor
private final class FrameProbe {
    var files: CGRect?
    var inspector: CGRect?
    var other: CGRect?
}
