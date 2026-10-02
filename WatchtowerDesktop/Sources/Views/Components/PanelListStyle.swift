import AppKit
import SwiftUI

extension NSColor {
    /// The detail backdrop `MainNavigationView` puts behind every tab — what
    /// the AI Chat conversation sits on, beside its lighter history panel.
    /// The Workbench workspace (page header, terminal, Board, Documents) and
    /// the selected row of a tabbed panel (`PanelTab`) paint it too, so they
    /// read as AI Chat does and can never drift from it.
    static var detailBackground: NSColor { .controlBackgroundColor }
}

extension View {
    /// Styles a `List` used as a side panel of a hand-built split (an
    /// `HSplitView` or `HStack`, not the leading column of a
    /// `NavigationSplitView`). `.sidebar` — and the automatic style, which
    /// resolves to it in such a column — requests the source-list vibrancy
    /// material; without its split-view backing that material samples the
    /// desktop wallpaper and tints the panel (owner reports: a brown chat
    /// history, a brown Workbench list and board). A plain list over the window
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

    /// A left panel whose rows are tabs (the Workbench sessions panel, the
    /// AI Chat history): the panel colour with the column's edge line drawn
    /// beneath the panel's content, so the selected row — filled with the
    /// detail backdrop up to the edge (`panelTab(isSelected:)`) — covers the
    /// line and runs on into the content beside it like a tab. The panel's
    /// list must not paint its own background (`clearPlainList()`), and the
    /// content beside the panel sits on `detailBackground()`.
    func panelSurface() -> some View {
        background(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .panelBackground()
    }

    /// A row of a `panelSurface()` list as a tab (`PanelTab`).
    func panelTab(isSelected: Bool) -> some View {
        modifier(PanelTab(isSelected: isSelected))
    }
}

/// A list row as a tab of the content beside its panel: inset from the
/// panel's leading edge by the plain List's own 8pt margin and running to
/// its trailing edge, rounded on the leading corners only. The selected row
/// is filled with the detail backdrop, which covers the panel's edge line at
/// that row (`panelSurface()`) so the tab merges into the content; other
/// rows have no fill but a faint one under the pointer. Shared by the
/// Workbench sessions panel and the AI Chat history so the two never drift.
struct PanelTab: ViewModifier {
    static let cornerRadius: CGFloat = 7
    /// The plain List keeps a margin of its own (8pt) past the row's
    /// trailing inset; the fill overshoots it and the list's clip ends it
    /// exactly at the panel's edge, whatever that margin is.
    static let trailingOverhang: CGFloat = 16

    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole tab, padding included, takes the pointer and any
            // gesture attached outside this modifier.
            .contentShape(Rectangle())
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: Self.cornerRadius, bottomLeadingRadius: Self.cornerRadius,
                    style: .continuous
                )
                .fill(fill)
                .padding(.trailing, -Self.trailingOverhang)
            }
            .onHover { isHovering = $0 }
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return Color(nsColor: .detailBackground) }
        return isHovering ? Color.primary.opacity(0.05) : .clear
    }
}
