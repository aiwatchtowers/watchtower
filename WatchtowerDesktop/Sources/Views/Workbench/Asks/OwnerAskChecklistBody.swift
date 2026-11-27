import SwiftUI
import WatchtowerCore
import ChatUI

/// A manual check's steps (spec 2026-10-03 Part 8, board #502): each marked
/// Works, Doesn't work (with "What happened?") or Didn't check; an item left
/// unmarked is sent as Didn't check. The summary line counts the marks.
/// Read-only for a closed ask. From the keyboard (board #412) the drawer's
/// cursor outlines a step, 1–3 mark it and Return goes into its note.
struct OwnerAskChecklistBody: View {
    let items: [OwnerAskCheckItem]
    let marks: [String: OwnerAskAnswer.CheckState]
    let notes: [String: String]
    let editable: Bool
    var mark: (String, OwnerAskAnswer.CheckState?) -> Void = { _, _ in }
    var setNote: (String, String) -> Void = { _, _ in }
    /// ⌘↩ (false) / ⌘⇧↩ (true) in a note: the ask's answer buttons.
    var onKey: (Bool) -> Void = { _ in }
    /// The drawer's keyboard cursor and its Return (board #412).
    var keyboardStop: OwnerAskKeyStop?
    var fieldFocus: OwnerAskFieldFocus?
    var onLeaveField: (() -> Void)?
    /// A step's **?** opens the chat about it (spec 2026-11-27 D2); nil
    /// draws none (a review ask, no CLI).
    var explain: ((AskExplainItem) -> Void)?

    /// The item of the step at this 0-based index: its 1-based position.
    static func stepItem(index: Int) -> AskExplainItem {
        .step(index + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let summary = OwnerAskPresentation.checkSummary(items, marks: marks)
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemView(item, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemView(_ item: OwnerAskCheckItem, index: Int) -> some View {
        let state = marks[item.id]
        let number = index + 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    MarkdownView(text: item.text)
                    if !item.hint.isEmpty {
                        MarkdownView(text: item.hint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let explain {
                    Spacer(minLength: Spacing.small)
                    let step = Self.stepItem(index: index)
                    AskExplainEntry(item: step, kind: .check, hasCLI: true) { explain(step) }
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(OwnerAskPresentation.checkStates.enumerated()), id: \.element.state) { index, option in
                    let value = option.state
                    Button {
                        mark(item.id, state == value ? nil : value)
                    } label: {
                        Label(option.label, systemImage: option.icon).font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(state == value ? color(value).opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
                            .foregroundStyle(state == value ? color(value) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!editable)
                    .help(editable ? "\(option.label) (press \(index + 1); Tab moves between steps)" : "")
                    .accessibilityAddTraits(state == value ? .isSelected : [])
                }
            }
            .padding(.leading, 18)
            // Editing, only Doesn't work asks what happened (only its note is
            // sent); a closed ask shows any note it was answered with.
            if editable ? state == .broken : !(notes[item.id] ?? "").isEmpty {
                noteView(item)
                    .padding(.leading, 18)
            }
        }
        .ownerAskKeyCursor(keyboardStop == .step(item.id))
        .id(OwnerAskKeyStop.step(item.id))
    }

    @ViewBuilder
    private func noteView(_ item: OwnerAskCheckItem) -> some View {
        if editable {
            CommentTextEditor(
                text: Binding(get: { notes[item.id] ?? "" }, set: { setNote(item.id, $0) }),
                placeholder: "What happened?",
                minHeight: CommentTextEditor.formMinHeight,
                maxHeight: CommentTextEditor.formMaxHeight,
                onSubmit: { onKey(false) },
                onShiftSubmit: { onKey(true) },
                onCancel: onLeaveField,
                focusRequest: OwnerAskFieldFocus.request(fieldFocus, for: .step(item.id))
            )
        } else if let note = notes[item.id], !note.isEmpty {
            MarkdownView(text: note, lineBreaks: true).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func color(_ state: OwnerAskAnswer.CheckState) -> Color {
        switch state {
        case .ok: .green
        case .broken: .red
        case .skipped: .secondary
        }
    }
}
