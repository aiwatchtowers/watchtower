import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The Desktop style guide's scale tokens (spec §1–§4), one copy for the
/// Desktop's DesignKit (which re-exports this module) and the phone's
/// DesignSystem. Views take their spacing, radii, fills and strokes from
/// here instead of literals.

/// Padding and stack spacing steps.
public enum Spacing {
    public static let tight: CGFloat = 2
    public static let small: CGFloat = 4
    public static let compact: CGFloat = 6
    public static let regular: CGFloat = 8
    public static let cozy: CGFloat = 10
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let page: CGFloat = 20
    public static let wide: CGFloat = 24
    public static let hero: CGFloat = 40
}

/// Corner radii.
public enum Radius {
    public static let mark: CGFloat = 4
    public static let control: CGFloat = 6
    public static let row: CGFloat = 8
    public static let container: CGFloat = 10
    public static let bubble: CGFloat = 16
    public static let pill: CGFloat = 18
}

/// Neutral and accent fills for rest, card, hover, selected and on states.
public enum Fill {
    public static let restOpacity = 0.04
    public static let cardOpacity = 0.06
    public static let hoverOpacity = 0.07
    public static let selectedOpacity = 0.12
    public static let onOpacity = 0.20

    public static let rest = Color.primary.opacity(restOpacity)
    public static let card = Color.primary.opacity(cardOpacity)
    public static let hover = Color.primary.opacity(hoverOpacity)
    public static let selected = Color.accentColor.opacity(selectedOpacity)
    public static let on = Color.accentColor.opacity(onOpacity)
}

/// A tinted chip: the tone at `fillOpacity` behind a `strokeOpacity` outline.
public enum ChipTint {
    public static let fillOpacity = 0.14
    public static let strokeOpacity = 0.3
    public static let strokeWidth: CGFloat = 0.5
}

/// Line widths and the hairline colour.
public enum Stroke {
    public static let hairline: CGFloat = 0.5
    public static let selection: CGFloat = 1.5

    /// The system separator colour of the platform.
    public static var hairlineColor: Color {
        #if canImport(AppKit)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }
}

/// Glyph sizes for chevrons, headers and composer buttons.
public enum IconSize {
    public static let chevron: CGFloat = 8
    public static let header: CGFloat = 14
    public static let composer: CGFloat = 16
    public static let composerLarge: CGFloat = 24
}

/// Letter spacing, in points.
public enum Tracking {
    /// Small uppercase labels: Home's zone titles.
    public static let caps: CGFloat = 0.6
}

/// The app's two standard animations.
public enum Motion {
    public static let toggle = Animation.snappy(duration: 0.15)
    public static let panel = Animation.easeInOut(duration: 0.2)
}

/// The soft shadow under floating elements.
public enum FloatingShadow {
    public static let color = Color.black.opacity(0.2)
    public static let radius: CGFloat = 3
    public static let y: CGFloat = 1
}
