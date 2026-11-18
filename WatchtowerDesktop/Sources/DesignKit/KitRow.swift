import SwiftUI

/// A selectable row of a list (style guide #719): full width on a rounded
/// plate, accent-tinted when selected, a neutral tint under the pointer.
/// A row with a status (a warning, say) passes its `Tone` as `tint`: the
/// plate keeps that tone at `ChipTint.fillOpacity`, hovered or not.
struct KitRow: ViewModifier {
    let isSelected: Bool
    var tint: Color?
    @State private var isHovered = false

    /// The plate's fill: selection wins over a tint, a tint over hover.
    static func fill(isSelected: Bool, isHovered: Bool, tint: Color? = nil) -> Color {
        if isSelected { return Fill.selected }
        if let tint { return tint.opacity(ChipTint.fillOpacity) }
        return isHovered ? Fill.hover : .clear
    }

    func body(content: Content) -> some View {
        let plate = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        content
            .padding(.vertical, Spacing.compact)
            .padding(.horizontal, Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(plate.fill(Self.fill(isSelected: isSelected, isHovered: isHovered, tint: tint)))
            .contentShape(plate)
            .onHover { isHovered = $0 }
            .animation(Motion.toggle, value: isHovered)
    }
}

extension View {
    public func kitRow(isSelected: Bool, tint: Color? = nil) -> some View {
        modifier(KitRow(isSelected: isSelected, tint: tint))
    }
}
