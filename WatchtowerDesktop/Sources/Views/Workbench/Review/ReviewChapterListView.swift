import SwiftUI
import WatchtowerCore

/// Deep mode's left column (board #328): the chapters — title, changed
/// lines, a check mark once every file is Viewed. The current chapter opens
/// into its files (the same rows as the Quick file list).
struct ReviewChapterListView: View {
    let model: ReviewChangesModel

    var body: some View {
        List {
            if model.aiChaptersPending {
                HStack {
                    Text("AI chapters are ready").font(.callout)
                    Spacer(minLength: 4)
                    Button("Use them") { model.useAIChapters() }.controlSize(.small)
                }
            }
            if model.chapters.isEmpty {
                Text("No changes").foregroundStyle(.secondary)
            }
            ForEach(model.chapters) { chapter in
                Section {
                    header(chapter)
                    if chapter.key == model.currentChapterKey {
                        ForEach(files(of: chapter)) { ReviewFileListView.row($0, model: model) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func files(of chapter: ReviewChapter) -> [ReviewDiffFile] {
        chapter.paths.compactMap { path in model.files.first { $0.path == path } }
    }

    private func header(_ chapter: ReviewChapter) -> some View {
        let done = ReviewChapters.done(chapter) { model.isViewed($0) }
        let current = chapter.key == model.currentChapterKey
        return HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 1) {
                Text(chapter.title).fontWeight(current ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                if let caption = ReviewPresentation.sourceCaption(chapter.source) {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if chapter.core {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Core of the change")
                    .accessibilityLabel("Core")
            }
            Spacer(minLength: 4)
            Text("\(chapter.changedLines) lines").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { try? await model.selectChapter(chapter.key) } } // a failure lands in lastError
        .accessibilityAddTraits(.isButton)
    }
}
