import Foundation

/// One deep-review chapter: a chapter of the round's map over the files the view shows.
package struct ReviewChapter: Equatable, Sendable, Identifiable {
    package let key: String
    package let title: String
    package let paths: [String]
    package let changedLines: Int
    package let core: Bool
    /// Who split the diff: the session's agent, the overview model, or the mechanical rule.
    package let source: Source
    package var id: String { key }

    package enum Source: String, Sendable { case agent, ai, mechanical }

    package init(
        key: String,
        title: String,
        paths: [String],
        changedLines: Int,
        core: Bool,
        source: Source = .mechanical
    ) {
        self.source = source
        self.key = key
        self.title = title
        self.paths = paths
        self.changedLines = changedLines
        self.core = core
    }
}

/// Chapter helpers that outlived the Swift chapter builder (board #1025:
/// chapters come from Go's `review map`).
package enum ReviewChapters {
    /// Reading time at 400 changed lines per hour, rounded up.
    package static func estimateMinutes(changedLines: Int) -> Int {
        guard changedLines > 0 else { return 0 }
        return (changedLines * 60 + 399) / 400
    }

    package static func done(_ chapter: ReviewChapter, isViewed: (String) -> Bool) -> Bool {
        chapter.paths.allSatisfy(isViewed)
    }
}

package struct ReviewProgress: Equatable, Sendable {
    package let viewedLines: Int
    package let totalLines: Int
    package let chaptersDone: Int
    package let chapterCount: Int

    package static func make(
        files: [ReviewDiffFile], chapters: [ReviewChapter], isViewed: (String) -> Bool
    ) -> Self {
        // Collapsed (generated, lock) files are not review work: they count in neither number.
        let counted = files.filter { $0.collapsedReason == nil }
        return Self(
            viewedLines: counted.filter { isViewed($0.path) }.reduce(0) { $0 + $1.additions + $1.deletions },
            totalLines: counted.reduce(0) { $0 + $1.additions + $1.deletions },
            chaptersDone: chapters.filter { ReviewChapters.done($0, isViewed: isViewed) }.count,
            chapterCount: chapters.count
        )
    }
}
