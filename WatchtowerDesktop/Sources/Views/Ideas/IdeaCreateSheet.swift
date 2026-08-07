import SwiftUI

// MARK: - IdeaCreateSheet
//
// Owner-authored idea/note/decision, created directly (active, `source:
// "owner"`) via `IdeasViewModel.createManual` — the manual-entry counterpart
// to the mined pipeline.
struct IdeaCreateSheet: View {
    let vm: IdeasViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Idea.Kind = .idea
    @State private var title: String = ""
    @State private var essence: String = ""

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
            Text("New Idea")
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
                    Text("Idea").tag(Idea.Kind.idea)
                    Text("Note").tag(Idea.Kind.note)
                    Text("Decision").tag(Idea.Kind.decision)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Essence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $essence)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 140)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("Create") {
                vm.createManual(kind: kind.rawValue, title: title, essence: essence)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}
