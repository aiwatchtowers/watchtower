import SwiftUI

/// Where a `PanelSplit` keeps its panel's width: dragged within `range`,
/// remembered under `key` across launches, `ideal` until first dragged.
struct PanelSplitWidth {
    let key: String
    let range: ClosedRange<Double>
    let ideal: Double

    func clamped(_ width: Double) -> Double {
        min(max(width, range.lowerBound), range.upperBound)
    }
}

/// Main content with a resizable side panel on its trailing edge (style
/// guide #719), the layout of the Workbench target panel
/// (`WorkbenchBoardView.panel`) for a detail that would otherwise open in a
/// sheet or a popup: the panel sits beside the main content rather than over
/// it, behind a leading hairline, and its leading edge is a
/// `PanelResizeHandle`. It slides in and out with `Motion.panel`. Not an
/// `.inspector`, which acts on the window and would squeeze a split pane.
struct PanelSplit<Main: View, Panel: View>: View {
    let isPanelShown: Bool
    let width: PanelSplitWidth
    @ViewBuilder let main: Main
    @ViewBuilder let panel: Panel

    @AppStorage private var storedWidth: Double
    @State private var liveWidth: Double?

    init(
        isPanelShown: Bool,
        width: PanelSplitWidth,
        @ViewBuilder main: () -> Main,
        @ViewBuilder panel: () -> Panel
    ) {
        self.isPanelShown = isPanelShown
        self.width = width
        self.main = main()
        self.panel = panel()
        _storedWidth = AppStorage(wrappedValue: width.ideal, width.key)
    }

    var body: some View {
        HStack(spacing: 0) {
            main.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPanelShown {
                panel
                    .frame(width: liveWidth ?? width.clamped(storedWidth))
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) { Divider() }
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
