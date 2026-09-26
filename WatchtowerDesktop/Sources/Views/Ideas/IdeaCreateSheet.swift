import SwiftUI
import WatchtowerCore

// MARK: - IdeaCreateSheet
//
// Owner-authored idea/note/decision, created directly (active, `source:
// "owner"`) via `IdeasViewModel.createManual` — the manual-entry counterpart
// to the mined pipeline. `allowedKinds` scopes which kinds the sheet offers:
// the Ideas tab presents it with the default idea/note pair, while the
// Decisions segment (Task 10) re-presents the same sheet with
// `allowedKinds: [.decision]`. `initialKind` picks which of them the sheet
// opens on — the Ideas tab passes its visible segment.
struct IdeaCreateSheet: View {
    let vm: IdeasViewModel
    let allowedKinds: [Idea.Kind]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dictationCenter) private var dictationCenter
    @State private var kind: Idea.Kind
    @State private var title: String = ""
    @State private var essence: String = ""
    @State private var createError: String?

    init(vm: IdeasViewModel, allowedKinds: [Idea.Kind] = [.idea, .note], initialKind: Idea.Kind? = nil) {
        self.vm = vm
        self.allowedKinds = allowedKinds
        // A seed outside `allowedKinds` would leave the picker on a segment it
        // doesn't render, so it falls back rather than being trusted.
        let seed = initialKind.flatMap { allowedKinds.contains($0) ? $0 : nil }
        _kind = State(initialValue: seed ?? allowedKinds.first ?? .idea)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            formContent
            Divider()
            sheetFooter
        }
        .frame(width: 460, height: 420)
    }

    private var sheetHeader: some View {
        HStack {
            Text("New \(Self.label(for: kind))")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Kind", selection: $kind) {
                    ForEach(allowedKinds, id: \.self) { candidate in
                        Text(Self.label(for: candidate)).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Essence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        DictationButton(text: $essence, mode: .idea, targetID: "idea-create.essence") {
                            if title.isEmpty { title = $0 }
                        }
                    }
                    TextEditor(text: $essence)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 140)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .dictationHighlight(targetID: "idea-create.essence", center: dictationCenter)
                }
            }
            .padding()
        }
    }

    private var sheetFooter: some View {
        HStack {
            if let createError {
                Label(createError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Create", action: create)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private static func label(for kind: Idea.Kind) -> String {
        switch kind {
        case .idea: return "Idea"
        case .note: return "Note"
        case .decision: return "Decision"
        }
    }

    /// Dismisses only once the row actually exists. Closing regardless would
    /// throw away the owner's typed title and essence on a failed write, with
    /// the sheet gone before its error could be read.
    private func create() {
        guard vm.createManual(kind: kind.rawValue, title: title, essence: essence) != nil else {
            createError = vm.errorMessage ?? "Couldn't create the idea."
            return
        }
        dismiss()
    }
}
