import Foundation

package struct ReviewIntentItem: Equatable, Sendable, Identifiable {
    package let key: String
    package let text: String
    package var id: String { key }

    package init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

/// Wrap-up helpers: the intent checklist and the comment grouping.
package enum ReviewWrapUp {
    package static func intentItems(_ context: [ReviewContextItem]) -> [ReviewIntentItem] {
        context.map { ReviewIntentItem(key: "target:\($0.targetId)", text: $0.text) }
    }

    package static func commentsByChapter(
        _ comments: [ReviewComment], chapters: [ReviewChapter]
    ) -> [(title: String, comments: [ReviewComment])] {
        var chapterOfPath: [String: Int] = [:]
        for (index, chapter) in chapters.enumerated() {
            for path in chapter.paths where chapterOfPath[path] == nil { chapterOfPath[path] = index }
        }
        var grouped: [Int: [ReviewComment]] = [:]
        var general: [ReviewComment] = []
        for comment in comments where comment.status != .resolved {
            if let path = comment.path, let index = chapterOfPath[path] {
                grouped[index, default: []].append(comment)
            } else {
                general.append(comment)
            }
        }
        var result: [(title: String, comments: [ReviewComment])] = chapters.indices.compactMap { index in
            grouped[index].map { (title: chapters[index].title, comments: $0) }
        }
        if !general.isEmpty { result.append((title: "General", comments: general)) }
        return result
    }

    package static func intentCommentBody(partial: Bool, item: ReviewIntentItem, note: String) -> String {
        let head = "\(partial ? "Partly done" : "Not done"): \(item.text)"
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? head : "\(head) — \(trimmed)"
    }
}
