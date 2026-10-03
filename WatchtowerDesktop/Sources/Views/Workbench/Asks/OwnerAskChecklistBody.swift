import SwiftUI
import WatchtowerCore

/// A manual check's steps (spec 2026-10-03 Part 8): each marked Ok, Broken
/// (with a note) or Skipped; an item left unmarked is sent as skipped. The
/// summary line counts the marks. Read-only for a closed ask.
struct OwnerAskChecklistBody: View {
    let items: [OwnerAskCheckItem]
    let marks: [String: OwnerAskAnswer.CheckState]
    let notes: [String: String]
    let editable: Bool
    var mark: (String, OwnerAskAnswer.CheckState?) -> Void = { _, _ in }
    var setNote: (String, String) -> Void = { _, _ in }

    private static let states: [(OwnerAskAnswer.CheckState, String)] = [(.ok, "Ok"), (.broken, "Broken"), (.skipped, "Skipped")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OwnerAskPresentation.checkSummary(items, marks: marks))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemView(item, number: index + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemView(_ item: OwnerAskCheckItem, number: Int) -> some View {
        let state = marks[item.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !item.hint.isEmpty {
                        Text(item.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(Self.states, id: \.0) { value, label in
                    Button {
                        mark(item.id, state == value ? nil : value)
                    } label: {
                        Text(label).font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(state == value ? color(value).opacity(0.2) : Color.secondary.opacity(0.08), in: Capsule())
                            .foregroundStyle(state == value ? color(value) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!editable)
                    .accessibilityAddTraits(state == value ? .isSelected : [])
                }
            }
            .padding(.leading, 18)
            if state == .broken || !(notes[item.id] ?? "").isEmpty {
                noteView(item)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func noteView(_ item: OwnerAskCheckItem) -> some View {
        let state = marks[item.id]
        if editable {
            TextField(state == .broken ? "What broke? (required)" : "Note", text: Binding(get: { notes[item.id] ?? "" }, set: { setNote(item.id, $0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
        } else if let note = notes[item.id], !note.isEmpty {
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
