import SwiftUI
import WatchtowerKit

/// The check steps (mockup 11): one card of "1." and the step with its
/// hint, then OK, Broken and Skipped as 44 pt icon buttons; tapping the
/// marked one again clears it. A note goes with a broken step (required) or
/// one that has a note. A step left unmarked goes as skipped.
struct CheckAskView: View {
    let rows: [AskFormModel.CheckRow]
    let model: AskViewModel
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { CardRowDivider() }
                    step(row, number: index + 1)
                }
            }
            .card(.plain, padding: EdgeInsets())
            Text("A step you leave unmarked goes as skipped.")
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
                SheetField(label: row.needsNote ? "What is broken? (required)" : "Note") {
                    TextField("Note", text: noteBinding(row), axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(!isEditable)
                        .accessibilityLabel("Note on step \(number)")
                }
            }
        }
        .padding(Card.padding)
    }

    /// Borderless buttons: in a scroll view's card, buttons of the default
    /// style would still share the row's tap.
    private func choices(_ row: AskFormModel.CheckRow, step: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(row.choices) { choice in
                Button {
                    model.toggleCheck(choice.state, for: row.id)
                } label: {
                    Image(systemName: choice.symbol)
                        .font(.title2)
                        // A step that cannot change (Sending…, applied) draws no colored mark.
                        .foregroundStyle(isEditable ? choice.tone.color : PhoneTone.secondary.color)
                        .frame(width: PhoneMetrics.minTouch, height: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(choice.label), step \(step)")
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
            }
        }
        .disabled(!isEditable)
    }

    private func noteBinding(_ row: AskFormModel.CheckRow) -> Binding<String> {
        Binding(get: { model.draft.checkNotes[row.id] ?? "" }, set: { model.setCheckNote($0, for: row.id) })
    }
}
