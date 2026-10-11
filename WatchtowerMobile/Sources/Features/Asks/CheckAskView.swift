import SwiftUI
import WatchtowerKit

/// The check steps: each one OK, Broken or Skipped, with a note (required
/// when broken). A step left unmarked goes as skipped.
struct CheckAskView: View {
    let rows: [AskFormModel.CheckRow]
    let model: AskViewModel
    let isEditable: Bool

    private static let states: [OwnerAskAnswer.CheckState] = [.ok, .broken, .skipped]

    var body: some View {
        Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(index + 1). \(row.text)").font(.body)
                    if !row.hint.isEmpty {
                        Text(row.hint).font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Step \(index + 1)", selection: stateBinding(row)) {
                        Text("Not marked").tag(OwnerAskAnswer.CheckState?.none)
                        ForEach(Self.states, id: \.self) { state in
                            Text(AskText.check(state)).tag(Optional(state))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                    .disabled(!isEditable)
                    if row.state == .broken || !row.note.isEmpty {
                        TextField(row.needsNote ? "What is broken? (required)" : "Note", text: noteBinding(row), axis: .vertical)
                            .lineLimit(1...4)
                            .frame(minHeight: 44)
                            .disabled(!isEditable)
                            .accessibilityLabel("Note on step \(index + 1)")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("A step you leave unmarked goes as skipped.")
        }
    }

    private func stateBinding(_ row: AskFormModel.CheckRow) -> Binding<OwnerAskAnswer.CheckState?> {
        Binding(get: { row.state }, set: { model.setCheck($0, for: row.id) })
    }

    private func noteBinding(_ row: AskFormModel.CheckRow) -> Binding<String> {
        Binding(get: { model.draft.checkNotes[row.id] ?? "" }, set: { model.setCheckNote($0, for: row.id) })
    }
}
