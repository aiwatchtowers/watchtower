import SwiftUI
import WatchtowerKit

/// The check steps (mockup 11, #1787): one card of "1." and the step with
/// its hint, then Works, Doesn't work and Didn't check — the Mac's words —
/// as labelled buttons sharing the width (stacked at accessibility text
/// sizes); tapping the marked one again clears it. A note goes with a step
/// that doesn't work (required) or one that has a note. The footer says what
/// an unmarked step sends and, until one is marked, that Send needs a mark.
struct CheckAskView: View {
    let rows: [AskFormModel.CheckRow]
    let footer: String
    let model: AskViewModel
    let isEditable: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { CardRowDivider() }
                    step(row, number: index + 1)
                }
            }
            .card(.plain, padding: EdgeInsets())
            Text(footer)
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ row: AskFormModel.CheckRow, number: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text("\(number).").font(TypeScale.time).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(row.text).font(TypeScale.rowTitle)
                    if !row.hint.isEmpty {
                        Text(row.hint).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            choices(row, step: number)
            if row.state == .broken || !row.note.isEmpty {
                SheetField(label: row.state == .broken ? AskText.brokenNote : AskText.stepNote) {
                    TextField(AskText.stepNote, text: noteBinding(row), axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(!isEditable)
                        .accessibilityLabel("Note on step \(number)")
                }
            }
        }
        .padding(Card.padding)
    }

    @ViewBuilder
    private func choices(_ row: AskFormModel.CheckRow, step: Int) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Spacing.small) { choiceButtons(row, step: step) }
        } else {
            HStack(spacing: Spacing.small) { choiceButtons(row, step: step) }
        }
    }

    /// Borderless buttons: in a scroll view's card, buttons of the default
    /// style would still share the row's tap.
    private func choiceButtons(_ row: AskFormModel.CheckRow, step: Int) -> some View {
        ForEach(row.choices) { choice in
            // A step that cannot change (Sending…, applied) draws no colored mark.
            let tint = isEditable ? choice.tone.color : PhoneTone.secondary.color
            Button {
                model.toggleCheck(choice.state, for: row.id)
            } label: {
                // Icon over the word: three words fit a narrow phone side by side.
                VStack(spacing: Spacing.tight) {
                    Image(systemName: choice.symbol)
                    Text(choice.label)
                }
                .font(choice.isSelected ? TypeScale.rowEmphasis : TypeScale.rowTitle)
                .padding(.vertical, Spacing.small)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(choice.isSelected ? tint : Color.primary)
                .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch)
                .background(
                    choice.isSelected ? tint.opacity(ChipTint.fillOpacity) : Fill.card,
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(
                        choice.isSelected ? tint : Stroke.hairlineColor,
                        lineWidth: choice.isSelected ? Stroke.selection : Stroke.hairline
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!isEditable)
            .accessibilityLabel("\(choice.label), step \(step)")
            .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
        }
    }

    private func noteBinding(_ row: AskFormModel.CheckRow) -> Binding<String> {
        Binding(get: { model.draft.checkNotes[row.id] ?? "" }, set: { model.setCheckNote($0, for: row.id) })
    }
}
