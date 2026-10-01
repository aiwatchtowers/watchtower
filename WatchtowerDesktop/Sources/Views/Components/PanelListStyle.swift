import AppKit
import SwiftUI

extension NSColor {
    /// The detail backdrop `MainNavigationView` puts behind every tab — what
    /// the AI Chat conversation sits on, beside its lighter history panel.
    /// The Projects workspace (page header, terminal, Board, Documents) and
    /// its selected session row paint it too, so they read as AI Chat does
    /// and can never drift from it.
    static var detailBackground: NSColor { .controlBackgroundColor }
}

extension View {
    /// Styles a `List` used as a side panel of a hand-built split (an
    /// `HSplitView` or `HStack`, not the leading column of a
    /// `NavigationSplitView`). `.sidebar` — and the automatic style, which
    /// resolves to it in such a column — requests the source-list vibrancy
    /// material; without its split-view backing that material samples the
    /// desktop wallpaper and tints the panel (owner reports: a brown chat
    /// history, a brown Projects list and board). A plain list over the window
    /// background matches the app's own `SidebarView`.
    func panelListStyle() -> some View {
        clearPlainList().panelBackground()
    }

    /// `panelListStyle()` for a list inside the Projects workspace (Board,
    /// Documents): the same plain list, over the detail backdrop.
    func workspaceListStyle() -> some View {
        clearPlainList().detailBackground()
    }

    /// A plain list that paints no background of its own, for a list whose
    /// container paints it (`panelSurface()`).
    func clearPlainList() -> some View {
        listStyle(.plain).scrollContentBackground(.hidden)
    }

    /// The side panels' background: the app sidebar's colour.
    func panelBackground() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
    }

    /// The darker surface a tab's content sits on (`NSColor.detailBackground`).
    func detailBackground() -> some View {
        background(Color(nsColor: .detailBackground))
    }

    /// The Projects tab's left panel: the panel colour with the column's
    /// edge line drawn beneath the panel's content, so the selected session
    /// row — filled with the detail backdrop up to the edge — covers the line
    /// and runs on into the workspace like a tab into its content. The
    /// panel's list must not paint its own background (`clearPlainList()`).
    func panelSurface() -> some View {
        background(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .panelBackground()
    }
}
