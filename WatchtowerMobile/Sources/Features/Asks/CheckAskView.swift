import SwiftUI
import WatchtowerKit

/// The check steps (design pass A5): "1." and the step with its hint, then
/// OK, Broken and Skipped as 44 pt icon buttons; tapping the marked one
/// again clears it. A note goes with a broken step (required) or one that
/// has a note. A step left unmarked goes as skipped.
struct CheckAskView: View {
    let rows: [AskFormModel.CheckRow]
    let model: AskViewModel
    let isEditable: Bool

    var body: some View {
        Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(row.text).font(.body)
                            if !row.hint.isEmpty {
                                Text(row.hint).font(TypeScale.meta).foregroundStyle(.secondary)
                            }
                        }
                    }
                    choices(row, step: index + 1)
                    if row.state == .broken || !row.note.isEmpty {
                        TextField(row.needsNote ? "What is broken? (required)" : "Note", text: noteBinding(row), axis: .vertical)
                            .lineLimit(1...4)
                            .frame(minHeight: 44)
                            .disabled(!isEditable)
                            .accessibilityLabel("Note on step \(index + 1)")
                    }
                }
                .padding(.vertical, Spacing.small)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("A step you leave unmarked goes as skipped.")
        }
    }

    /// Borderless buttons: in a List row, buttons of the default style all
    /// fire on a tap anywhere in the row.
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
                        .frame(width: 44, height: 44)
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
