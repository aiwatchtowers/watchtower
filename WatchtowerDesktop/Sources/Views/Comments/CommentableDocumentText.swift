import SwiftUI
import WatchtowerCore

/// `DocumentTextView` with Google-Docs-style commenting: selecting text shows
/// a floating Comment button next to it (also "Comment…" in the context
/// menu), which opens a composer right at the selection. Used by the chat
/// artifact panel.
///
/// The composer remembers the selection and `contentID` it opened on: if the
/// text is re-rendered while it is open, saving is refused with the typed
/// text kept (`SelectionCommentCheck`), since the remembered offsets point
/// into text that is gone.
struct CommentableDocumentText: View {
    let text: NSAttributedString
    let contentID: String
    @Binding var selection: NSRange
    /// The composer's typed text. Held by the host so it outlives this view
    /// (a document that briefly fails to read replaces it).
    @Binding var composerText: String
    var horizontalInset: CGFloat = ReadableColumn.minInset
    var scrollTarget: DocumentScrollTarget?
    /// Saves a comment on `range`; returns whether it was saved (the composer
    /// then closes and clears). On false the composer stays open with the
    /// text and a generic note; the host's own error line says why.
    let onComment: (_ body: String, _ range: NSRange) async -> Bool
    let onClick: (Int) -> Void

    @State private var selectionRect: CGRect?
    @State private var composing = false
    @State private var saving = false
    @State private var composeRange = NSRange(location: 0, length: 0)
    @State private var composeContentID = ""
    @State private var composeError: String?
    @State private var buttonOrigin: CGPoint?
    @State private var containerSize = CGSize.zero

    private static let buttonSize = CGSize(width: 96, height: 24)

    var body: some View {
        GeometryReader { geo in
            DocumentTextView(
                text: text,
                contentID: contentID,
                selection: $selection,
                horizontalInset: horizontalInset,
                selectionRect: $selectionRect,
                onCommentRequest: openComposer,
                scrollTarget: scrollTarget,
                onClick: onClick
            )
            .overlay(alignment: .topLeading) { commentButton(in: geo.size) }
            .onAppear { containerSize = geo.size }
            .onChange(of: geo.size) { _, size in containerSize = size }
        }
    }

    @ViewBuilder
    private func commentButton(in size: CGSize) -> some View {
        let live = selection.length > 0
            ? SelectionCommentPlacement.origin(selection: selectionRect, container: size, button: Self.buttonSize)
            : nil
        // While composing the button stays where it opened (top-left when the
        // selection was off screen): it anchors the popover.
        if let origin = composing ? buttonOrigin ?? live ?? .zero : live {
            Button(action: openComposer) {
                Label("Comment", systemImage: "text.bubble")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
            }
            .buttonStyle(FloatingCommentButtonStyle())
            .help("Comment on the selection")
            .popover(isPresented: $composing, arrowEdge: .trailing) { composer }
            // Padding, not offset: the popover anchors on the layout frame.
            .padding(.leading, origin.x)
            .padding(.top, origin.y)
        }
    }

    private func openComposer() {
        guard selection.length > 0 else { return }
        composeRange = selection
        composeContentID = contentID
        composeError = nil
        buttonOrigin = SelectionCommentPlacement.origin(
            selection: selectionRect, container: containerSize, button: Self.buttonSize
        )
        composing = true
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment on the selection").font(.headline)
            CommentTextEditor(text: $composerText, placeholder: "Write a comment", focusOnAppear: true,
                              minHeight: 90, maxHeight: 220, onSubmit: save)
                .frame(width: 320)
            if let composeError {
                Text(composeError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("⌘↩ or ⌃↩ to comment").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    composerText = ""
                    composing = false
                }
                Button("Comment", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(12)
    }

    private var canSave: Bool {
        !saving && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        if let refusal = SelectionCommentCheck.refusal(openedOn: composeContentID, current: contentID) {
            composeError = refusal
            return
        }
        let (body, range) = (composerText, composeRange)
        saving = true
        Task {
            // A failed save keeps the composer open with the typed text.
            if await onComment(body, range) {
                composerText = ""
                composing = false
            } else {
                composeError = "Could not save the comment."
            }
            saving = false
        }
    }
}

/// The floating Comment button (#165): an opaque, shadowed chip — the default
/// translucent bezel let the document's text show through it.
private struct FloatingCommentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: configuration.isPressed ? .controlColor : .windowBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
