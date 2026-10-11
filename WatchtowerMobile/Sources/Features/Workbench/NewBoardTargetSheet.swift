import SwiftUI
import WatchtowerKit

/// New target on the board (spec §6.3): title (required), intent, priority
/// (Medium by default) and a parent among this workbench's live targets.
/// Add sends `board_target_create` and closes; the target appears when the
/// Mac has added it.
struct NewBoardTargetSheet: View {
    let replica: WorkbenchReplicaModel
    let writer: BoardWriter
    @State private var draft: NewBoardTargetDraft
    @State private var sending = false
    @State private var sendError: String?
    @Environment(\.dismiss) private var dismiss

    init(replica: WorkbenchReplicaModel, writer: BoardWriter, workbenchID: Int64, parentID: Int64? = nil) {
        self.replica = replica
        self.writer = writer
        _draft = State(initialValue: NewBoardTargetDraft(workbenchID: workbenchID, parentID: parentID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.body)
                        .accessibilityLabel("Title")
                    TextField("Intent (optional)", text: $draft.intent, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityLabel("Intent")
                }
                Section {
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(WorkbenchTargetPriority.knownValues, id: \.self) {
                            Text(BoardRowModel.priorityName($0)).tag($0)
                        }
                    }
                    Picker("Parent", selection: $draft.parentID) {
                        Text("None").tag(Int64?.none)
                        ForEach(NewBoardTargetDraft.parentOptions(workbenchID: draft.workbenchID, snapshot: replica.snapshot)) {
                            Text($0.label).lineLimit(1).tag(Int64?.some($0.id))
                        }
                    }
                } footer: {
                    Text("Your Mac adds it to the board as todo.")
                }
            }
            .navigationTitle("New target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!draft.canCreate || sending)
                        .accessibilityLabel("Add the target")
                }
            }
            .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError ?? "")
            }
        }
    }

    private func add() {
        sending = true
        Task {
            defer { sending = false }
            do {
                if try await writer.create(draft) { dismiss() }
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }
}
