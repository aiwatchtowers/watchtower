import SwiftUI

extension View {
    /// The board card's outline: a hairline separator border, or the accent
    /// selection stroke when selected. The fill stays the caller's
    /// `background`, because a card's fill depends on its state.
    func card(selected: Bool = false) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: Radius.row)
                .strokeBorder(selected ? Color.accentColor : Stroke.hairlineColor,
                              lineWidth: selected ? Stroke.selection : Stroke.hairline)
        )
    }
}
