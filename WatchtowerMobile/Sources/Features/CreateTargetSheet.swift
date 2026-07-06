import SwiftUI

/// Minimal task-creation sheet: one text field → a `task_create`
/// ActionRequest. The desktop's relay processor creates the target row; it
/// arrives back on the phone via slice hydration (there is no optimistic
/// phantom row for creates — the pending overlay only decorates EXISTING
/// rows, and a failure surfaces in the Tasks failed-action banner).
struct CreateTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    /// Called with the trimmed, non-empty task text.
    let onCreate: (String) async -> Void

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("What needs to happen?", text: $text, axis: .vertical)
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let value = trimmed
                        Task { await onCreate(value) }
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
