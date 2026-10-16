import SwiftUI
import WatchtowerCore

/// An open New Task sheet (board #411): where the new target goes.
struct WorkbenchNewTargetRequest: Identifiable, Equatable {
    /// Go's `workbench target add` cap, counted in Unicode scalars as Go
    /// counts runes.
    static let titleLimit = 200

    let id = UUID()
    /// The parent target; nil = the top level.
    let parentID: Int?
}

/// The owner's New Task sheet: title, priority, description and the parent
/// the request named. Created through `WorkbenchBoardViewModel.createTarget`.
struct WorkbenchNewTargetSheet: View {
    let request: WorkbenchNewTargetRequest
    let vm: WorkbenchBoardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var intent = ""
    @State private var priority = "medium"
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.parentID == nil ? "New Task" : "New Sub-task").font(.headline)
            Text(parentLabel).font(.callout).foregroundStyle(.secondary)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(create)
            Picker("Priority", selection: $priority) {
                ForEach(WorkbenchBoardCard.editablePriorities, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $intent)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            if let error = vm.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            vm.dismissError()
            titleFocused = true
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool {
        !trimmedTitle.isEmpty && trimmedTitle.unicodeScalars.count <= WorkbenchNewTargetRequest.titleLimit
            && !vm.isCreatingTarget
    }

    private var parentLabel: String {
        guard let parentID = request.parentID else { return "On the board's top level" }
        let text = WorkbenchBoardOutline.find(parentID, in: vm.roots).map { WorkbenchBoardCard.title($0.target.text) } ?? ""
        return "Under \(WorkbenchTargetNumber.label(parentID))  \(text)"
    }

    private func create() {
        guard canCreate else { return }
        Task {
            await vm.createTarget(title: title, intent: intent, priority: priority, parentID: request.parentID)
        }
    }
}
