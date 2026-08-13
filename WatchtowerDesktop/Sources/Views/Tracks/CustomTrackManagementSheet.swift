import SwiftUI
import WatchtowerCore

/// Creates a CUSTOM track from a free-text "what to watch" request. The CLI
/// (`watchtower tracks create`) composes the watch instruction AND persists the
/// track in one shot, so this is a compose→confirm flow rather than the
/// draft-then-add one the observer sheet used. Ported from the removed
/// `ObserverManagementSheet`.
///
/// When `linkedTargetID` is set, the created track is linked to that target for
/// context (used by the target detail "Watch" button — Task 14).
struct CustomTrackManagementSheet: View {
    let linkedTargetID: Int?
    /// Notified with the created draft so the caller can refresh / navigate.
    var onCreated: ((TrackDraft) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var request = ""
    @State private var created: TrackDraft?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    init(linkedTargetID: Int? = nil, onCreated: ((TrackDraft) -> Void)? = nil) {
        self.linkedTargetID = linkedTargetID
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch a custom track").font(.title3).bold()
            Text("Describe what to watch for — AI turns it into a focused instruction and names the track.")
                .font(.caption).foregroundColor(.secondary)
            TextField("e.g. the HashBank refund decision and who owns it", text: $request, axis: .vertical)
                .lineLimit(2...4)
                .disabled(isGenerating || created != nil)

            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red).lineLimit(3)
            }

            if let created {
                createdPreview(created)
            }

            Divider()
            HStack {
                Spacer()
                if created == nil {
                    Button {
                        Task { await generate() }
                    } label: {
                        if isGenerating {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Creating…") }
                        } else {
                            Label("Create with AI", systemImage: "sparkles")
                        }
                    }
                    .disabled(isGenerating || request.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func createdPreview(_ draft: TrackDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Custom track created", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundColor(.green)
            Text(draft.title).font(.headline)
            if !draft.instruction.isEmpty {
                Text(draft.instruction)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func generate() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let draft = try await TrackComposeService(runner: runner).compose(
                text: request, targetID: linkedTargetID)
            created = draft
            onCreated?(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
