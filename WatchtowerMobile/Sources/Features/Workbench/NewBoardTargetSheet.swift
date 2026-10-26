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
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    SheetField(label: "Title") {
                        TextField("Title", text: $draft.title, axis: .vertical)
                            .lineLimit(2...4)
                            .accessibilityLabel("Title")
                    }
                    SheetField(label: "Intent (optional)") {
                        TextField("Intent (optional)", text: $draft.intent, axis: .vertical)
                            .lineLimit(3...8)
                            .frame(minHeight: PhoneMetrics.minTouch * 2, alignment: .topLeading)
                            .accessibilityLabel("Intent")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(title: "Priority") {
                            Picker("Priority", selection: $draft.priority) {
                                ForEach(WorkbenchTargetPriority.knownValues, id: \.self) {
                                    Text(BoardRowModel.priorityName($0)).tag($0)
                                }
                            }
                            .labelsHidden()
                        }
                        CardRowDivider()
                        SettingsRow(title: "Parent") {
                            Picker("Parent", selection: $draft.parentID) {
                                Text("None").tag(Int64?.none)
                                ForEach(NewBoardTargetDraft.parentOptions(workbenchID: draft.workbenchID, snapshot: replica.snapshot)) {
                                    Text($0.label).lineLimit(1).tag(Int64?.some($0.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .card(.plain, padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
                    Text("Your Mac adds it to the board as todo.")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.small)
                }
                .padding(Spacing.large)
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PrimaryActionBar(primary: BarAction(title: "Add the target", isEnabled: draft.canCreate && !sending) { add() })
            }
            .navigationTitle("New target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
