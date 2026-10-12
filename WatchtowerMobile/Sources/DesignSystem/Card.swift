import SwiftUI

/// A card's look (design pass spec §2.5): `plain` for detail blocks,
/// `waiting` for "Waiting for you" and asks, `highlighted` for the current
/// or next meeting. A card never contains another card; rows inside one are
/// flat.
enum CardStyle: Equatable {
    case plain, waiting, highlighted
}

enum Card {
    /// The default inner padding: 12 horizontal, 10 vertical.
    static let padding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)

    struct Paint: Equatable {
        let fill: Color
        let stroke: Color
        let lineWidth: CGFloat
    }

    /// The fill and stroke of `style` in `scheme`. The waiting card gets its
    /// colour from `PhoneTone.waitingForYou`; the design layer never names
    /// orange.
    static func paint(_ style: CardStyle, scheme: ColorScheme) -> Paint {
        switch style {
        case .plain:
            Paint(fill: Color(.secondarySystemBackground), stroke: Color(.separator), lineWidth: 0.5)
        case .waiting:
            Paint(
                fill: PhoneTone.waitingForYou.color.opacity(scheme == .dark ? 0.06 : 0.10),
                stroke: PhoneTone.waitingForYou.color.opacity(scheme == .dark ? 0.30 : 0.45),
                lineWidth: 1
            )
        case .highlighted:
            Paint(fill: Color.accentColor.opacity(scheme == .dark ? 0.14 : 0.10), stroke: .accentColor, lineWidth: 1.5)
        }
    }
}

private struct CardModifier: ViewModifier {
    let style: CardStyle
    let padding: EdgeInsets
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let paint = Card.paint(style, scheme: scheme)
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(paint.fill, in: shape)
            .overlay(shape.strokeBorder(paint.stroke, lineWidth: paint.lineWidth))
    }
}

extension View {
    /// The card recipe: radius 12 (continuous), the style's paint, and
    /// `padding` inside. Cards sit on `Color(.systemBackground)`.
    func card(_ style: CardStyle = .plain, padding: EdgeInsets = Card.padding) -> some View {
        modifier(CardModifier(style: style, padding: padding))
    }
}
