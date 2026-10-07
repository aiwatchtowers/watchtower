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
/// loss saves and Esc cancels. A failed save keeps the editor and the
/// draft (the panel's error row says why) — after a switch too: the draft
/// stays bound to its own target and is back when the panel returns to it.
struct WorkbenchPanelDescription: View {
    let targetID: Int
    let intent: String
    /// `WorkbenchBoardViewModel.saveIntent(_:original:for:)` on the target
    /// the editor was opened on, with the text it opened with: whether the
    /// text is saved.
    let onSave: (_ text: String, _ original: String, _ targetID: Int) -> Bool

    static let foldedLines = 6

    @State private var draft = ""
    /// The description the editor opened with: a save never writes this
    /// snapshot over a newer description (`saveIntent`'s `original`).
    @State private var original = ""
    /// The target the editor was opened on: a save that arrives after the
    /// panel moved to another target (focus loss while it switches) still
    /// goes to this one, never to the new one.
    @State private var editingTargetID: Int?
    @State private var expanded = false
    @State private var foldedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isEditing: Bool { editingTargetID == targetID }
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
        .onChange(of: targetID) {
            // Moving to another target is a focus loss: the draft saves to
            // its own target. A failure (shown in the error row) keeps the
            // draft on that target, so returning to it reopens the editor.
            save()
            expanded = false
        }
        // The panel closing (✕, Esc, a reload that empties the path) saves
        // explicitly rather than trusting the editor's teardown focus loss;
        // a save that already ran cleared `editingTargetID`, so this one is
        // a no-op then.
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
            CommentTextEditor(text: $draft, placeholder: "Describe the target…", focusOnAppear: true,
                              minHeight: 80, maxHeight: 360, onSubmit: save, onCancel: cancel, onEndEditing: save)
            Text("⌘↩ saves, Esc cancels")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func beginEditing() {
        draft = intent
        original = intent
        editingTargetID = targetID
    }

    /// ⌘↩ and focus loss. After a save or a cancel the editor is gone, so
    /// the focus loss its removal causes saves nothing.
    private func save() {
        guard let id = editingTargetID else { return }
        if onSave(draft, original, id) { editingTargetID = nil }
    }

    private func cancel() {
        editingTargetID = nil
    }
}
