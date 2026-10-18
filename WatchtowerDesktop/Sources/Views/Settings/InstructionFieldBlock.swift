import SwiftUI
import WatchtowerCore

/// One instruction field: an optional grey global text above, the editable
/// text with its `n / limit` counter and Save, and the yellow "You keep
/// saying this" block. Shared by Settings → System and the workbench's
/// Agent Settings; the owner of the view holds the draft and does the CLI call.
struct InstructionFieldBlock: View {
    let title: String
    let caption: String
    let stored: String
    let limit: Int
    let suggestions: [InstructionSuggestion]
    let detail: (InstructionSuggestion) -> String
    let error: String?
    let busy: Bool
    /// nil = no unsaved edit (the field shows `stored`).
    @Binding var draft: String?
    let onSave: (String) -> Void
    let onDecide: (InstructionSuggestion, Bool) -> Void
    /// The global text shown grey (first 2 lines) with "Edit in Settings".
    var globalText: String?
    var onEditGlobal: (() -> Void)?

    private var unsavedEdit: Bool { OwnerInstructionsState.hasUnsavedEdit(draft: draft, stored: stored) }

    var body: some View {
        let shown = draft ?? stored
        let count = OwnerInstructionsState.runeCount(shown)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            if let globalText {
                globalRow(globalText)
            }
            TextEditor(text: Binding(get: { draft ?? stored }, set: { draft = $0 }))
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Text("\(count) / \(limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count > limit ? .red : .secondary)
                Spacer()
                Button("Save") { onSave(shown) }
                    .disabled(!unsavedEdit || busy)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            suggestionsBlock
        }
        .padding(.vertical, 4)
    }

    private func globalRow(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: "\n")
        return HStack(alignment: .firstTextBaseline) {
            Text(text.isEmpty ? "No global text yet." : lines)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let onEditGlobal {
                Button("Edit in Settings", action: onEditGlobal).buttonStyle(.link).font(.caption)
            }
        }
    }

    @ViewBuilder
    private var suggestionsBlock: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("You keep saying this — \(suggestions.count) suggestion\(suggestions.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                if unsavedEdit {
                    Text("Save or revert your edit first").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(suggestions) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(row.text)”")
                            Text(detail(row)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") { onDecide(row, true) }
                            .disabled(unsavedEdit)
                        Button("Dismiss") { onDecide(row, false) }
                    }
                    .disabled(busy)
                }
            }
            .padding(8)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
