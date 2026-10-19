import SwiftUI

/// A selectable row of a list (style guide #719): full width on a rounded
/// plate, accent-tinted when selected, a neutral tint under the pointer.
struct KitRow: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    /// The plate's fill: selection wins over hover.
    static func fill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Fill.selected }
        return isHovered ? Fill.hover : .clear
    }

    func body(content: Content) -> some View {
        let plate = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        content
            .padding(.vertical, Spacing.compact)
            .padding(.horizontal, Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(plate.fill(Self.fill(isSelected: isSelected, isHovered: isHovered)))
            .contentShape(plate)
            .onHover { isHovered = $0 }
            .animation(Motion.toggle, value: isHovered)
    }
}

extension View {
    func kitRow(isSelected: Bool) -> some View {
        modifier(KitRow(isSelected: isSelected))
    }
}
