import SwiftUI
import WatchtowerCore

/// Deep's Chapters foot (#963): where the review stands in the chapter, and
/// the one action that marks all its files Viewed and moves to the next
/// chapter that is not done.
struct ReviewChapterFooter: View {
    let model: ReviewChangesModel

    var body: some View {
        if let key = model.currentChapterKey,
           let index = model.chapters.firstIndex(where: { $0.key == key }) {
            let chapter = model.chapters[index]
            let viewed = chapter.paths.filter { model.isViewed($0) }.count
            HStack {
                Text("Chapter \(index + 1) of \(model.chapters.count) · \(viewed) of \(chapter.paths.count) files viewed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // A failure lands in lastError. ⌥⌘↓ is the file header's next unviewed file.
                Button("Chapter viewed →") { Task { try? await model.markChapterViewed(key) } }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.option, .command])
                    .help("Mark every file of this chapter Viewed and go to the next one (⌥⌘↩)")
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
        }
    }
}
