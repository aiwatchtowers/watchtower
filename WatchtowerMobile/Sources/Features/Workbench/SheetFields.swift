import SwiftUI

/// A form's label over a field (mockup 12's `.lbl` and `.field`): the
/// label in secondary footnote, the value or input in a box on the card
/// fill under a hairline.
struct SheetField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(label)
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.small)
            content
                .font(.subheadline)
                .padding(.horizontal, Spacing.cozy)
                .padding(.vertical, Spacing.regular)
                .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline)
                )
        }
    }
}
