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
            .panelBackground()
    }

    /// The side panels' background, for a whole tab that should read as one
    /// surface with them (the Projects tab: its page, terminal, Board and
    /// Documents) instead of the darker detail backdrop of `MainNavigationView`.
    func panelBackground() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
    }
}
