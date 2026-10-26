import SwiftUI

/// A card's look, the Desktop's `.card()` at phone size (mockups 1–5):
/// `plain` for blocks and row groups, `waiting` for an approval or another
/// waiting-for-you element that is a card of its own, `highlighted` for the
/// selected board card or the meeting in focus. A card never contains
/// another card; rows inside one are flat.
enum CardStyle: Equatable {
    case plain, waiting, highlighted
}

enum Card {
    /// The Desktop's container radius (continuous).
    static let radius = Radius.container
    /// The default inner padding: 12 horizontal, 10 vertical.
    static let padding = EdgeInsets(top: Spacing.cozy, leading: Spacing.medium, bottom: Spacing.cozy, trailing: Spacing.medium)

    struct Paint: Equatable {
        let fill: Color
        let stroke: Color
        let lineWidth: CGFloat
    }

    /// The fill and stroke of `style`. Plain is the soft `Fill.card` under
    /// a hairline, never an opaque system fill; waiting is the same recipe
    /// in the waiting tone (from `PhoneTone.waitingForYou`; the design layer
    /// never names orange); highlighted is the Desktop's selected card.
    static func paint(_ style: CardStyle) -> Paint {
        switch style {
        case .plain:
            Paint(fill: Fill.card, stroke: Stroke.hairlineColor, lineWidth: Stroke.hairline)
        case .waiting:
            Paint(
                fill: PhoneTone.waitingForYou.color.opacity(Fill.cardOpacity),
                stroke: PhoneTone.waitingForYou.color,
                lineWidth: Stroke.hairline
            )
        case .highlighted:
            Paint(fill: Fill.selected, stroke: .accentColor, lineWidth: Stroke.selection)
        }
    }
}

private struct CardModifier: ViewModifier {
    let style: CardStyle
    let padding: EdgeInsets

    func body(content: Content) -> some View {
        let paint = Card.paint(style)
        let shape = RoundedRectangle(cornerRadius: Card.radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(paint.fill, in: shape)
            .overlay(shape.strokeBorder(paint.stroke, lineWidth: paint.lineWidth))
    }
}

extension View {
    /// The card recipe: `Card.radius` (continuous), the style's paint, and
    /// `padding` inside. Cards sit on `Color(.systemBackground)`.
    func card(_ style: CardStyle = .plain, padding: EdgeInsets = Card.padding) -> some View {
        modifier(CardModifier(style: style, padding: padding))
    }
}
