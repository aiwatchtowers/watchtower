import SwiftUI

/// The one look for every popover's content (#363): the system popover
/// material shows through, as in stock macOS popovers. The popover itself
/// already draws that material; what made ours opaque was what we painted on
/// it — a plain `List` fills its rows' backdrop, and a comment field filled
/// itself with the opaque text background. Apply `.popoverSurface()` to the
/// root of every `.popover { … }` (and an `NSPopover`'s hosted root).
extension View {
    public func popoverSurface() -> some View {
        scrollContentBackground(.hidden)
            .environment(\.onPopoverSurface, true)
    }
}

extension EnvironmentValues {
    /// Set by `popoverSurface()`: a field draws a translucent well instead
    /// of its opaque fill, so the material stays visible behind it.
    @Entry public var onPopoverSurface = false
}
