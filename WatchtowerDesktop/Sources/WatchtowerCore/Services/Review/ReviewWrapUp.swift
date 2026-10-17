import Foundation

package struct ReviewIntentItem: Equatable, Sendable, Identifiable {
    package let key: String
    package let text: String
    /// The overview's raw coverage status for this item, nil without an overview.
    package let aiStatus: String?
    package var id: String { key }

    package init(key: String, text: String, aiStatus: String? = nil) {
        self.key = key
        self.text = text
        self.aiStatus = aiStatus
    }
}

/// Wrap-up helpers: the intent checklist and the comment grouping.
package enum ReviewWrapUp {
    package static func intentItems(_ context: [ReviewContextItem]) -> [ReviewIntentItem] {
        context.map { ReviewIntentItem(key: "target:\($0.targetId)", text: $0.text) }
    }

    /// One item per context item, keyed and worded by the context item; the
    /// overview's coverage entry with that item's 1-based index adds its
    /// status. The model's wording never reaches the key, so a mark survives
    /// a new overview that phrases the item differently.
    package static func intentItems(
        _ context: [ReviewContextItem], coverage: [(index: Int, status: String)]
    ) -> [ReviewIntentItem] {
        var statusOf: [Int: String] = [:]
        for entry in coverage where statusOf[entry.index] == nil { statusOf[entry.index] = entry.status }
        return context.enumerated().map { offset, item in
            ReviewIntentItem(key: "target:\(item.targetId)", text: item.text, aiStatus: statusOf[offset + 1])
        }
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
