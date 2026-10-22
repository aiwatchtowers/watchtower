import SwiftUI
import WatchtowerCore

/// What the New idea row holds while the owner types; kept by the Inbox so
/// it survives a filter switch, cleared once the idea exists.
struct InboxNewIdeaDraft: Equatable {
    var kind: Idea.Kind = .idea
    var title = ""
    var essence = ""

    var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The Ideas filter's inline New idea row (R9, replaces `IdeaCreateSheet`):
/// Idea or Note, a title and the essence, **Create** (⌘Return) and
/// **Cancel**. The owner's idea is created active (`createManual`); the
/// Inbox then opens it (`onCreated`). A failed write keeps the draft and
/// says why.
struct InboxNewIdeaRow: View {
    let ideas: IdeasViewModel
    @Binding var draft: InboxNewIdeaDraft
    /// The new idea's id, once it exists.
    let onCreated: (Int) async -> Void
    let onCancel: () -> Void

    @State private var isCreating = false
    @State private var createError: String?

    /// ⌘Return creates.
    static let createShortcut = KeyboardShortcut(.return, modifiers: .command)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Text("New \(draft.kind.label)")
                    .font(.callout.weight(.semibold))
                Spacer()
                KitSegmentedPicker(
                    title: "Kind",
                    selection: $draft.kind,
                    segments: [KitSegment(value: Idea.Kind.idea, title: "Idea"),
                               KitSegment(value: Idea.Kind.note, title: "Note")]
                )
                .fixedSize()
            }
            TextField("Title", text: $draft.title)
                .textFieldStyle(.kit)
            TextField("Essence", text: $draft.essence, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.kit)
            HStack(spacing: Spacing.regular) {
                if let createError {
                    Label(createError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.kitQuiet)
                    .disabled(isCreating)
                Button("Create") { Task { await create() } }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(Self.createShortcut)
                    .disabled(!draft.canCreate || isCreating)
            }
        }
        .padding(Spacing.medium)
        .card()
    }

    /// Creates the idea; the draft is cleared only once the row exists.
    func create() async {
        guard draft.canCreate, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        guard let id = await ideas.createManual(kind: draft.kind.rawValue, title: draft.title,
                                                essence: draft.essence) else {
            createError = ideas.errorMessage ?? "Couldn't create the idea."
            return
        }
        createError = nil
        draft = InboxNewIdeaDraft()
        await onCreated(id)
    }
}
