import SwiftUI
import WatchtowerCore

/// The current chapter's checklist under the diff (board #328): every lens
/// with questions, a checkbox per question and Comment… to turn one into a
/// design comment. Lens notes (a refused or odd `review.md`) lead.
struct ReviewChecklistView: View {
    let model: ReviewChangesModel
    let compose: (ReviewChangesPaneView.ComposeRequest) -> Void
    @State private var expanded = true

    var body: some View {
        if let chapterKey = model.currentChapterKey {
            Divider()
            DisclosureGroup("Checklist", isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.lensNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.lenses.filter { !$0.items.isEmpty }) { lens in
                            lensSection(lens, chapterKey: chapterKey)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func lensSection(_ lens: ReviewLens, chapterKey: String) -> some View {
        let marks = model.checks(forChapter: chapterKey).filter { $0.lens == lens.id }
        return VStack(alignment: .leading, spacing: 3) {
            Text(lens.name).font(.caption.weight(.semibold))
            ForEach(lens.items, id: \.key) { item in
                let state = marks.first { $0.itemKey == item.key }?.state
                HStack(spacing: 6) {
                    Toggle(item.text, isOn: Binding(
                        get: { state == .checked || state == .commented },
                        set: { checked in
                            // A failure lands in lastError.
                            try? model.setCheck(chapterKey: chapterKey, lens: lens.id, itemKey: item.key, checked: checked)
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(model.round?.status != "open")
                    Spacer(minLength: 4)
                    Button(state == .commented ? "Commented" : "Comment…") {
                        let chapter = model.chapters.first { $0.key == chapterKey }?.title ?? chapterKey
                        compose(.init(title: "\(lens.name): comment", prefill: "\(chapter) — \(item.text)") { body, _ in
                            try model.commentOnCheck(chapterKey: chapterKey, lens: lens.id, item: item, body: body)
                        })
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.round?.status != "open")
                }
                .font(.callout)
            }
        }
    }
}
