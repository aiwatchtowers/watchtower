import SwiftUI
import WatchtowerCore

/// A section title inside the target panel (Description, Sub-tasks, Asks,
/// Images, Comments), so every section reads the same.
struct WorkbenchDetailSectionHeader: View {
    let title: String
    let systemImage: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A status or priority menu's label: a tinted capsule with an icon and a
/// chevron, so it reads as a control rather than a bare tag.
struct WorkbenchDetailMenuLabel: View {
    let text: String
    let systemImage: String
    let color: Color
    /// A read-only value (a group's status) drops the chevron.
    var isMenu = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            if isMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }
}

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
            WorkbenchDetailSectionHeader(title: "Description", systemImage: "text.alignleft")
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
        // than trusting the editor's teardown focus loss; a save that already
        // ran dropped the draft, so this one is a no-op then.
        .onDisappear { save() }
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
                              minHeight: 80, maxHeight: 360, onSubmit: save, onCancel: cancel, onEndEditing: save)
            Text("⌘↩ saves, Esc cancels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func beginEditing() {
        vm.beginDescriptionEdit(targetID)
    }

    /// ⌘↩ and focus loss, on the target this view shows. After a save or a
    /// cancel the editor is gone, so the focus loss its removal causes saves
    /// nothing.
    private func save() {
        vm.saveDescription(for: targetID)
    }

    private func cancel() {
        vm.cancelDescriptionEdit(targetID)
    }
}
