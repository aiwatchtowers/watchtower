import SwiftUI

/// The Desktop style guide's scale tokens (spec §1–§4). Views take their
/// spacing, radii, fills and strokes from here instead of literals.

/// Padding and stack spacing steps.
enum Spacing {
    static let tight: CGFloat = 2
    static let small: CGFloat = 4
    static let compact: CGFloat = 6
    static let regular: CGFloat = 8
    static let cozy: CGFloat = 10
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let page: CGFloat = 20
    static let wide: CGFloat = 24
    static let hero: CGFloat = 40
}

/// Corner radii.
enum Radius {
    static let mark: CGFloat = 4
    static let control: CGFloat = 6
    static let row: CGFloat = 8
    static let container: CGFloat = 10
    static let bubble: CGFloat = 16
    static let pill: CGFloat = 18
}

/// Neutral and accent fills for rest, card, hover, selected and on states.
enum Fill {
    static let restOpacity = 0.04
    static let cardOpacity = 0.06
    static let hoverOpacity = 0.07
    static let selectedOpacity = 0.12
    static let onOpacity = 0.20

    static let rest = Color.primary.opacity(restOpacity)
    static let card = Color.primary.opacity(cardOpacity)
    static let hover = Color.primary.opacity(hoverOpacity)
    static let selected = Color.accentColor.opacity(selectedOpacity)
    static let on = Color.accentColor.opacity(onOpacity)
}

/// A tinted chip: the tone at `fillOpacity` behind a `strokeOpacity` outline.
enum ChipTint {
    static let fillOpacity = 0.14
    static let strokeOpacity = 0.3
    static let strokeWidth: CGFloat = 0.5
}

/// Line widths and the hairline colour.
enum Stroke {
    static let hairline: CGFloat = 0.5
    static let selection: CGFloat = 1.5

    static var hairlineColor: Color { Color(nsColor: .separatorColor) }
}

/// Glyph sizes for chevrons, headers and composer buttons.
enum IconSize {
    static let chevron: CGFloat = 8
    static let header: CGFloat = 14
    static let composer: CGFloat = 16
    static let composerLarge: CGFloat = 24
}

/// The app's two standard animations.
enum Motion {
    static let toggle = Animation.snappy(duration: 0.15)
    static let panel = Animation.easeInOut(duration: 0.2)
}

/// The soft shadow under floating elements.
enum FloatingShadow {
    static let color = Color.black.opacity(0.2)
    static let radius: CGFloat = 3
    static let y: CGFloat = 1
}
