import SwiftUI

/// One question page, the full-screen form of mockup 4's inline ask: the
/// question, its options as 44 pt rows (a picked one on `Fill.selected`
/// under an accent line, a recommended one marked "recommended"), and
/// Other. A single-select question takes one option, a multi-select one any
/// number.
struct QuestionAskView: View {
    let page: AskFormModel.QuestionPage
    let model: AskViewModel
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(page.question)
                .font(TypeScale.rowEmphasis)
                .accessibilityAddTraits(.isHeader)
            ForEach(page.options) { option in
                Button {
                    model.pick(option.label, in: page)
                } label: {
                    OptionRowLabel(option: option, multi: page.multi)
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel(option.recommended ? "\(option.label), recommended" : option.label)
                .accessibilityHint(option.description)
                .accessibilityAddTraits(option.isPicked ? .isSelected : [])
            }
            SheetField(label: "Other") {
                TextField("Your own answer", text: otherBinding, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(!isEditable)
                    .accessibilityLabel("Other answer")
            }
            Text(page.multi ? "Pick any that apply, or answer in Other." : "Pick one, or answer in Other.")
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
        }
    }

    private var otherBinding: Binding<String> {
        Binding(get: { model.draft.picks[page.questionID]?.other ?? "" }, set: { model.setOther($0, for: page.questionID) })
    }
}

/// An option row on the inline ask's recipe: a picked option is the
/// selected plate under an accent line.
private struct OptionRowLabel: View {
    let option: AskFormModel.QuestionPage.Option
    let multi: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(option.isPicked ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(option.label).font(TypeScale.rowTitle.weight(.medium)).foregroundStyle(.primary)
                // A word on its own line, not an outlined code badge (A2).
                if option.recommended {
                    Text("Recommended").font(TypeScale.meta).foregroundStyle(PhoneTone.accent.color)
                }
                if !option.description.isEmpty {
                    Text(option.description).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.regular)
        .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
        .background(RowPlate.fill(isSelected: option.isPicked), in: shape)
        .overlay(shape.strokeBorder(
            option.isPicked ? Color.accentColor : Stroke.hairlineColor,
            lineWidth: option.isPicked ? Stroke.selection : Stroke.hairline
        ))
        .contentShape(shape)
    }

    private var symbol: String {
        if multi { return option.isPicked ? "checkmark.square.fill" : "square" }
        return option.isPicked ? "largecircle.fill.circle" : "circle"
    }
}
