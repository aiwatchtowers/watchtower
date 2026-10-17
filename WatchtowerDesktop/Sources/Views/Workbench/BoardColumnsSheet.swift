import SwiftUI
import WatchtowerCore

/// The header menu's "Board Columns…" (board #267, spec 2026-10-16 §6): each
/// status in board order with its columns — add, rename, drag to reorder,
/// delete, a description — and Hide on In Review / Blocked. Edits stay in a
/// `BoardColumnsDraft` until Save, which runs `watchtower workbench columns
/// --set -`; the sheet writes nothing itself and the board never sees the
/// draft. Stays open with Go's message when Save is refused.
struct BoardColumnsSheet: View {
    let vm: WorkbenchesViewModel
    let project: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BoardColumnsDraft?
    @State private var cardCounts: [Int64: Int] = [:]
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false
    /// A column with cards asked to be deleted: its draft id and notice.
    @State private var pendingDelete: (id: Int, notice: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Board Columns").font(.headline)
            Text("Columns inside each status. A status without columns shows one column under its own name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let draft {
                editor(draft)
                ForEach(draft.errors, id: \.self) { message in
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } else if loadError == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
            ForEach([loadError, saveError].compactMap { $0 }, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || draft == nil || draft?.errors.isEmpty == false)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load() }
        .alert(
            "Delete this column?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { pending in
            Button("Delete", role: .destructive) { draft?.delete(pending.id) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("\(pending.notice) It happens when you save.")
        }
    }

    private func editor(_ draft: BoardColumnsDraft) -> some View {
        List {
            ForEach(BoardColumnsDraft.statuses, id: \.self) { status in
                Section {
                    ForEach(draft.columns(of: status)) { column in
                        row(column)
                    }
                    .onMove { self.draft?.move(in: status, fromOffsets: $0, toOffset: $1) }
                    if draft.columns(of: status).isEmpty {
                        Text(draft.hidden.contains(status)
                             ? "Hidden while empty; cards already there stay visible until they move."
                             : "One column: “\(WorkbenchBoardCard.statusLabel(status))”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        self.draft?.add(to: status)
                    } label: {
                        Label("Add Column", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!draft.canAdd(to: status))
                } header: {
                    header(status, draft: draft)
                }
            }
        }
        .frame(height: 420)
    }

    private func header(_ status: String, draft: BoardColumnsDraft) -> some View {
        HStack {
            Text(WorkbenchBoardCard.statusLabel(status))
            Spacer()
            if WorkbenchBoardColumns.hideableStatuses.contains(status) {
                Toggle("Hide", isOn: Binding(
                    get: { draft.hidden.contains(status) },
                    set: { self.draft?.setHidden($0, for: status) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!draft.canHide(status) && !draft.hidden.contains(status))
                .help(draft.canHide(status) || draft.hidden.contains(status)
                      ? "No column for this status while it is empty"
                      : "A status with columns cannot be hidden — delete its columns first")
            }
        }
    }

    private func row(_ column: BoardColumnsDraft.Column) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: Binding(
                    get: { column.title },
                    set: { draft?.setTitle($0, of: column.id) }
                ))
                .textFieldStyle(.roundedBorder)
                TextField("Description (optional)", text: Binding(
                    get: { column.description },
                    set: { draft?.setDescription($0, of: column.id) }
                ), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }
            Button {
                delete(column.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this column")
            .accessibilityLabel("Delete \(column.title)")
        }
        .padding(.vertical, 2)
    }

    private func delete(_ id: Int) {
        guard let draft else { return }
        if let notice = draft.deleteNotice(for: id, cardCounts: cardCounts) {
            pendingDelete = (id, notice)
        } else {
            self.draft?.delete(id)
        }
    }

    private func load() async {
        do {
            let (def, counts) = try await vm.loadBoardColumns(projectID: project.id)
            draft = BoardColumnsDraft(def)
            cardCounts = counts
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = "Could not read the board columns: \(WorkbenchesViewModel.boardColumnsMessage(error))"
        }
    }

    private func save() {
        guard !saving, let draft, draft.errors.isEmpty else { return }
        saving = true
        Task {
            do {
                _ = try await vm.saveBoardColumns(draft.definition, projectID: project.id)
                dismiss()
            } catch is CancellationError {
                // The sheet closed: nothing to show.
            } catch {
                saveError = WorkbenchesViewModel.boardColumnsMessage(error)
            }
            saving = false
        }
    }
}
