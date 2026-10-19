import SwiftUI

extension View {
    /// A card: the `fill` in a row-radius rounded rectangle under a hairline
    /// separator border, or the accent selection stroke when selected. A
    /// caller whose fill depends on its state (the board card) passes
    /// `fill: nil` and keeps its own `background`.
    func card(selected: Bool = false, fill: Color? = Fill.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row)
        return background {
            if let fill { shape.fill(fill) }
        }
        .overlay(
            shape.strokeBorder(selected ? Color.accentColor : Stroke.hairlineColor,
                               lineWidth: selected ? Stroke.selection : Stroke.hairline)
        )
    }
}
