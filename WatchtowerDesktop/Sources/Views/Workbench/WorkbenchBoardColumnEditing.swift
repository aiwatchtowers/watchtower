import SwiftUI
import WatchtowerCore

// Columns edited on the Kanban's header row (#713 AI-14 §1, replacing the
// Board Columns… sheet). Every edit saves at once through
// `WorkbenchBoardViewModel.editColumns`; a refusal shows under the header
// row (`WorkbenchBoardColumnsRefusal`) and the board keeps what was stored.

/// A column header's menu — the right-click menu and the hover `…` button.
/// On a status's implicit column Rename and Description define its first
/// column and Add Column defines two; a hidden status's leftover column
/// offers only Show. The Other column has no menu (`isEditable`).
struct WorkbenchBoardColumnMenu: View {
    let column: WorkbenchBoardKanban.Column
    let vm: WorkbenchBoardViewModel
    let onDescription: () -> Void
    let onDelete: (Int64) -> Void

    static func isEditable(_ column: WorkbenchBoardKanban.Column) -> Bool {
        column.status != WorkbenchBoardKanban.otherStatus
    }

    var body: some View {
        let draft = vm.columnsDraft
        let status = column.status
        let label = WorkbenchBoardCard.statusLabel(status)
        if vm.boardColumns.isHidden(status) {
            Button("Show \(label)") { edit { $0.setHidden(false, for: status) } }
        } else {
            Button("Rename") { vm.renamingColumnKey = column.key }
            Button("Description…", action: onDescription)
            Divider()
            if let id = column.columnID {
                Button("Add Column Right") { add { $0.insertColumn(beside: id, in: status, after: true) } }
                    .disabled(!draft.canAdd(to: status))
                Button("Add Column Left") { add { $0.insertColumn(beside: id, in: status, after: false) } }
                    .disabled(!draft.canAdd(to: status))
                Button("Move Left") { edit { $0.move(id, by: -1) } }
                    .disabled(!draft.canMove(id, by: -1))
                Button("Move Right") { edit { $0.move(id, by: 1) } }
                    .disabled(!draft.canMove(id, by: 1))
                Divider()
                Button("Delete Column", role: .destructive) { onDelete(id) }
            } else {
                Button("Add Column") { add { $0.insertColumn(beside: nil, in: status, after: true) } }
                    .disabled(!draft.canAdd(to: status))
                if draft.canHide(status) {
                    Divider()
                    Button("Hide \(label)") { edit { $0.setHidden(true, for: status) } }
                }
            }
        }
    }

    private func edit(_ change: @escaping @MainActor (inout BoardColumnsDraft) -> Void) {
        Task { await vm.editColumns { change(&$0); return nil } }
    }

    private func add(_ insert: @escaping @MainActor (inout BoardColumnsDraft) -> Int?) {
        Task { await vm.editColumns { insert(&$0) } }
    }
}

/// The `+` at the end of the header row: Add column to a status, and Show
/// for a hidden status — the only way back for a hidden empty one, which
/// has no header to right-click.
struct WorkbenchBoardAddColumnMenu: View {
    let vm: WorkbenchBoardViewModel

    var body: some View {
        let draft = vm.columnsDraft
        Menu {
            Section("Add Column To") {
                ForEach(BoardColumnLayout.openStatusOrder, id: \.self) { status in
                    Button(WorkbenchBoardCard.statusLabel(status)) {
                        Task { await vm.editColumns { $0.appendColumn(to: status) } }
                    }
                    .disabled(!draft.canAdd(to: status))
                }
            }
            let hidden = WorkbenchBoardColumns.hideableStatuses.filter(vm.boardColumns.isHidden)
            if !hidden.isEmpty {
                Divider()
                ForEach(hidden, id: \.self) { status in
                    Button("Show \(WorkbenchBoardCard.statusLabel(status))") {
                        Task { await vm.editColumns { $0.setHidden(false, for: status); return nil } }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a column, or show a hidden status")
        .accessibilityLabel("Add column")
    }
}

/// A column title in rename mode: Return saves, Esc cancels, clicking away
/// saves.
struct WorkbenchBoardColumnTitleField: View {
    let column: WorkbenchBoardKanban.Column
    let vm: WorkbenchBoardViewModel
    @State private var text: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(column: WorkbenchBoardKanban.Column, vm: WorkbenchBoardViewModel) {
        self.column = column
        self.vm = vm
        _text = State(initialValue: column.title)
    }

    var body: some View {
        TextField("Column title", text: $text)
            .textFieldStyle(.kit)
            .font(.subheadline.weight(.semibold))
            .focused($focused)
            .onSubmit(save)
            .onExitCommand(perform: cancel)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onAppear { focused = true }
    }

    private func save() {
        guard !finished else { return }
        finished = true
        vm.renamingColumnKey = nil
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != column.title else { return }
        let column = column
        Task { await vm.editColumns { $0.rename(column.columnID, in: column.status, to: title); return nil } }
    }

    private func cancel() {
        finished = true
        vm.renamingColumnKey = nil
    }
}

/// Description…: one field, the header's tooltip and the agent's guidance
/// for the column.
struct WorkbenchBoardColumnDescriptionEditor: View {
    let column: WorkbenchBoardKanban.Column
    let vm: WorkbenchBoardViewModel
    let onClose: () -> Void
    @State private var text: String

    init(column: WorkbenchBoardKanban.Column, vm: WorkbenchBoardViewModel, onClose: @escaping () -> Void) {
        self.column = column
        self.vm = vm
        self.onClose = onClose
        _text = State(initialValue: column.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Description of \(column.title)").font(.headline)
            TextField("What belongs in this column", text: $text, axis: .vertical)
                .textFieldStyle(.kit)
                .lineLimit(2...5)
            Text("Shown as the column's tooltip and to agents as guidance.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.kitSecondary)
                Button("Save", action: save)
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.medium)
        .frame(width: 320)
    }

    private func save() {
        onClose()
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard description != column.description else { return }
        let column = column
        Task {
            await vm.editColumns { $0.describe(column.columnID, in: column.status, as: description); return nil }
        }
    }
}

/// The last column edit's refusal, under the header row.
struct WorkbenchBoardColumnsRefusal: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Text(message)
                .font(.caption)
                .foregroundStyle(Tone.error)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.kitQuiet)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            Spacer(minLength: 0)
        }
    }
}
