import SwiftUI
import WatchtowerCore

/// The panel's description (spec 2026-10-06 Part 3): folded to six lines
/// with Show all when longer; a click opens the editor, where ⌘↩ or focus
/// loss saves and Esc cancels. The draft lives in the view model per target
/// (`WorkbenchBoardViewModel.descriptionDraft(for:)`): a failed save keeps
/// the editor and the draft (the panel's error row says why) — after a
/// switch too, where the draft stays on its own target and is back when the
/// panel returns to it, whatever is edited meanwhile.
struct WorkbenchPanelDescription: View {
    let vm: WorkbenchBoardViewModel
    let targetID: Int
    let intent: String

    static let foldedLines = 6

    @State private var expanded = false
    @State private var foldedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isEditing: Bool { vm.descriptionDraft(for: targetID) != nil }

    /// The editor's text: this target's own draft.
    private var draft: Binding<String> {
        let id = targetID
        return Binding(get: { vm.descriptionDraft(for: id)?.text ?? "" },
                       set: { vm.setDescriptionDraft($0, for: id) })
    }
    private var isTruncated: Bool { fullHeight > foldedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Description", systemImage: "text.alignleft")
            if isEditing {
                editor
            } else if intent.isEmpty {
                Button("Add a description") { beginEditing() }
                    .buttonStyle(.link)
                    .font(.callout)
            } else {
                text
            }
        }
        // Moving to another target or closing the panel saves the editor in
        // the view model (`open`, `closeDetail`): a failure keeps the draft
        // on its own target, so returning to it reopens the editor.
        .onChange(of: targetID) { expanded = false }
        // The pane leaving the screen some other way saves explicitly rather
        // than trusting the editor's teardown focus loss. After `open` or
        // `closeDetail` this target is no longer the open one, so this does
        // nothing then — a failed save is not retried behind its error.
        .onDisappear { vm.saveDescriptionOnFocusLoss(for: targetID) }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(intent)
                .font(.body)
                .lineSpacing(4)
                .lineLimit(expanded ? nil : Self.foldedLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Both heights measured off screen, so Show all knows whether
                // there is more than six lines whatever is shown.
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        measured(lineLimit: Self.foldedLines) { foldedHeight = $0 }
                        measured(lineLimit: nil) { fullHeight = $0 }
                    }
                    .hidden()
                }
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
                .help("Click to edit the description")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Edits the description")
            if isTruncated {
                Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func measured(lineLimit: Int?, _ report: @escaping (CGFloat) -> Void) -> some View {
        Text(intent)
            .font(.body)
            .lineSpacing(4)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            CommentTextEditor(text: draft, placeholder: "Describe the target…", focusOnAppear: true,
                              minHeight: 80, maxHeight: 360, onSubmit: save, onCancel: cancel, onEndEditing: endEditing)
            Text(vm.isSavingDescription(targetID) ? "Saving…" : "⌘↩ saves, Esc cancels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func beginEditing() {
        vm.beginDescriptionEdit(targetID)
    }

    /// ⌘↩ on the target this view shows. The focus loss after a switch or a
    /// close arrives late, for a target no longer open, and saves nothing
    /// (`saveDescriptionOnFocusLoss`): the move already saved it.
    private func save() {
        Task { await vm.saveDescription(for: targetID) }
    }

    /// Focus loss: saves only while this target is the open one.
    private func endEditing() {
        vm.saveDescriptionOnFocusLoss(for: targetID)
    }

    private func cancel() {
        vm.cancelDescriptionEdit(targetID)
    }
}
