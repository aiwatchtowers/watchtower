import SwiftUI

/// Where a `PanelSplit` keeps its panel's width: dragged within `range`,
/// remembered under `key` across launches, `ideal` until first dragged.
public struct PanelSplitWidth {
    let key: String
    let range: ClosedRange<Double>
    let ideal: Double

    public init(key: String, range: ClosedRange<Double>, ideal: Double) {
        self.key = key
        self.range = range
        self.ideal = ideal
    }

    public func clamped(_ width: Double) -> Double {
        min(max(width, range.lowerBound), range.upperBound)
    }
}

/// Main content with a resizable side panel on its trailing edge (style
/// guide #719), for a detail that would otherwise open in a sheet or a
/// popup: the panel sits beside the main content (side by side, the main
/// content gives up the width), behind a leading hairline, and its leading
/// edge is a `PanelResizeHandle`. It slides in and out with `Motion.panel`.
/// The Workbench target panel (`WorkbenchBoardView.panel`) overlays the board
/// instead and is not built on this. Not an `.inspector`, which acts on the
/// window and would squeeze a split pane.
public struct PanelSplit<Main: View, Panel: View>: View {
    let isPanelShown: Bool
    let width: PanelSplitWidth
    /// The leading hairline; off when the main content is a `panelSurface()`
    /// list, whose own edge line a selected tab covers.
    let showsEdgeLine: Bool
    @ViewBuilder let main: Main
    @ViewBuilder let panel: Panel

    @AppStorage private var storedWidth: Double
    @State private var liveWidth: Double?

    public init(
        isPanelShown: Bool,
        width: PanelSplitWidth,
        showsEdgeLine: Bool = true,
        @ViewBuilder main: () -> Main,
        @ViewBuilder panel: () -> Panel
    ) {
        self.isPanelShown = isPanelShown
        self.width = width
        self.showsEdgeLine = showsEdgeLine
        self.main = main()
        self.panel = panel()
        _storedWidth = AppStorage(wrappedValue: width.ideal, width.key)
    }

    public var body: some View {
        HStack(spacing: 0) {
            main.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPanelShown {
                panel
                    .frame(width: liveWidth ?? width.clamped(storedWidth))
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        if showsEdgeLine { Divider() }
                    }
                    .overlay(alignment: .leading) {
                        PanelResizeHandle(width: $storedWidth, liveWidth: $liveWidth,
                                          range: width.range, growsLeftward: true)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(Motion.panel, value: isPanelShown)
    }
}
