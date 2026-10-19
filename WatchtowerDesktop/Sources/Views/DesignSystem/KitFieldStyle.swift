import SwiftUI

/// The kit's single-line text field (style guide #719): a text-coloured well
/// with a hairline edge that turns accent while it has focus, in place of
/// the stock bezel. On a popover it is a translucent well over the material,
/// as the comment field (`CommentTextEditor`) is.
struct KitFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        KitField(field: configuration)
    }
}

extension TextFieldStyle where Self == KitFieldStyle {
    static var kit: KitFieldStyle { KitFieldStyle() }
}

/// The field's body: a view, so it can track focus.
private struct KitField<Field: View>: View {
    let field: Field

    @Environment(\.onPopoverSurface) private var onPopoverSurface
    @FocusState private var isFocused: Bool

    var body: some View {
        let well = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        field
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, Spacing.compact)
            .padding(.vertical, Spacing.small)
            .background(well.fill(Color(nsColor: .textBackgroundColor).opacity(onPopoverSurface ? 0.5 : 1)))
            .overlay {
                if isFocused {
                    well.strokeBorder(Color.accentColor, lineWidth: Stroke.selection)
                } else {
                    well.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline)
                }
            }
            .animation(Motion.toggle, value: isFocused)
    }
}
