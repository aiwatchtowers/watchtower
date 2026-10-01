import SwiftUI
import WatchtowerCore

/// `DocumentTextView` with Google-Docs-style commenting: selecting text shows
/// a floating Comment button next to it (also "Comment…" in the context menu
/// and ⌥⌘M), which opens a composer right at the selection. Shared by the
/// project Documents pane and the chat artifact panel.
///
/// The composer remembers the selection and `contentID` it opened on: if the
/// text is re-rendered while it is open, saving is refused with the typed
/// text kept, since the remembered offsets point into text that is gone.
struct CommentableDocumentText: View {
    let text: NSAttributedString
    let contentID: String
    @Binding var selection: NSRange
    var horizontalInset: CGFloat = ReadableColumn.minInset
    var canComment = true
    /// Saves a comment on `range`; returns whether it was saved (the composer
    /// then closes and clears). On false the host shows why.
    let onComment: (_ body: String, _ range: NSRange) async -> Bool
    let onClick: (Int) -> Void

    @State private var selectionRect: CGRect?
    @State private var composing = false
    @State private var draft = ""
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
                onCommentRequest: canComment ? openComposer : nil,
                onClick: onClick
            )
            .overlay(alignment: .topLeading) { commentButton(in: geo.size) }
            .onAppear { containerSize = geo.size }
            .onChange(of: geo.size) { _, size in containerSize = size }
        }
        .background { shortcut }
    }

    @ViewBuilder
    private func commentButton(in size: CGSize) -> some View {
        let live = selection.length > 0 && canComment
            ? SelectionCommentPlacement.origin(selection: selectionRect, container: size, button: Self.buttonSize)
            : nil
        // While composing the button stays where it opened (top-left when the
        // selection was off screen): it anchors the popover.
        if let origin = composing ? buttonOrigin ?? live ?? .zero : live {
            Button(action: openComposer) {
                Label("Comment", systemImage: "text.bubble")
            }
            .controlSize(.small)
            .help("Comment on the selection (⌥⌘M)")
            .popover(isPresented: $composing, arrowEdge: .trailing) { composer }
            .offset(x: origin.x, y: origin.y)
        }
    }

    /// ⌥⌘M opens the composer from the keyboard, like Google Docs.
    private var shortcut: some View {
        Button("Comment", action: openComposer)
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(selection.length == 0 || !canComment)
            .hidden()
    }

    private func openComposer() {
        guard canComment, selection.length > 0 else { return }
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
            TextEditor(text: $draft).frame(width: 300, height: 90)
            if let composeError {
                Text(composeError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { composing = false }
                Button("Comment", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func save() {
        guard composeContentID == contentID else {
            composeError = "The text changed — select the passage again."
            return
        }
        let (body, range) = (draft, composeRange)
        Task {
            // A failed save keeps the composer open with the typed text.
            if await onComment(body, range) {
                draft = ""
                composing = false
            }
        }
    }
}
