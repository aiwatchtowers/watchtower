import AppKit
import SwiftUI

/// The drag strip on a side panel's edge: the owner drags it to resize the
/// panel within `range`. It draws nothing — the edge line is the panel's own
/// (`panelSurface()`, or a `Divider`), so a selected row can cover it — and
/// shows whatever is behind it. `liveWidth` follows the drag; `width` (an
/// `@AppStorage` value, so it survives a relaunch) is written once, when the
/// drag ends. A panel on the trailing side sets `growsLeftward`. The statics
/// below are the Workbench sessions panel's defaults (`range` defaults to
/// `widthRange`); `PanelSplit`, the ask drawer and the target panel pass
/// their own `range`.
struct PanelResizeHandle: View {
    static let defaultWidth: Double = 260
    static let widthRange: ClosedRange<Double> = 200...480
    /// The strip's width.
    static let thickness: CGFloat = 7

    @Binding var width: Double
    @Binding var liveWidth: Double?
    var range: ClosedRange<Double> = Self.widthRange
    /// A panel on the trailing side widens as the pointer moves left.
    var growsLeftward = false
    @State private var dragStart: Double?
    @State private var cursorPushed = false

    static func clamp(_ width: Double) -> Double {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    var body: some View {
        Color.clear
            .frame(width: Self.thickness)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !cursorPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorPushed = true
                } else if !inside {
                    popCursor()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? clamped(width)
                        dragStart = start
                        let delta = Double(value.translation.width)
                        liveWidth = clamped(start + (growsLeftward ? -delta : delta))
                    }
                    .onEnded { _ in
                        if let liveWidth { width = liveWidth }
                        liveWidth = nil
                        dragStart = nil
                    }
            )
            .onDisappear {
                popCursor()
                liveWidth = nil
                dragStart = nil
            }
            .accessibilityHidden(true)
    }

    private func clamped(_ width: Double) -> Double {
        min(max(width, range.lowerBound), range.upperBound)
    }

    /// Balanced with the hover push: hiding the panel under the pointer must
    /// not leave the resize cursor stuck.
    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
