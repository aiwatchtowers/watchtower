import SwiftUI

/// The one look for every popover's content (#363): the system popover
/// material shows through, as in stock macOS popovers. The popover itself
/// already draws that material; what made ours opaque was what we painted on
/// it — a plain `List` fills its rows' backdrop, and a comment field filled
/// itself with the opaque text background. Apply `.popoverSurface()` to the
/// root of every `.popover { … }` (and an `NSPopover`'s hosted root).
extension View {
    func popoverSurface() -> some View {
        scrollContentBackground(.hidden)
            .environment(\.onPopoverSurface, true)
    }
}

extension EnvironmentValues {
    /// Set by `popoverSurface()`: a field draws a translucent well instead
    /// of its opaque fill, so the material stays visible behind it.
    @Entry var onPopoverSurface = false
}

/// The main action of a popover form: prominent while it can run, the plain
/// bordered look while disabled. A disabled `.borderedProminent` button
/// draws its white label at reduced opacity on a pale fill of the accent
/// color, and under the Graphite accent (or any light accent in the light
/// theme) that fill is nearly the label's color — the button reads as a
/// blank gray plate. The bordered style keeps a dimmed but legible label.
struct PopoverPrimaryButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        if isEnabled {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

extension PrimitiveButtonStyle where Self == PopoverPrimaryButtonStyle {
    static var popoverPrimary: PopoverPrimaryButtonStyle { PopoverPrimaryButtonStyle() }
}
