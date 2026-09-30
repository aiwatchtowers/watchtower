import AppKit
import SwiftUI

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
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
