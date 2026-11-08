import Foundation

/// What the reviewer's per-turn brief is built from (board #1025, tech spec
/// §6): the round's chapters in reading order, the summary and the chapter
/// open on screen. A value of its own, so the reviewer does not depend on
/// where chapters come from: `ReviewChangesModel.reviewerMapInput` fills it
/// from the round's `ReviewMap` (chapter danger levels) and the overview.
package struct ReviewerMapInput: Equatable, Sendable {
    package struct Chapter: Equatable, Sendable {
        package let key: String
        package let title: String
        /// The chapter's danger as one word (`breaking`, `significant`,
        /// `normal` from the map; before the map is in, the overview's
        /// highest risk); "" = not known.
        package let level: String
        package let paths: [String]

        package init(key: String, title: String, level: String, paths: [String]) {
            self.key = key
            self.title = title
            self.level = level
            self.paths = paths
        }
    }

    package var chapters: [Chapter]
    /// The overview's summary; "" while there is none.
    package var summary: String
    package var openChapterKey: String?

    package init(chapters: [Chapter], summary: String, openChapterKey: String?) {
        self.chapters = chapters
        self.summary = summary
        self.openChapterKey = openChapterKey
    }

    package static let empty = Self(chapters: [], summary: "", openChapterKey: nil)
}

/// The compact branch map each reviewer turn carries (business item 8): the
/// chapters with their danger, the summary and the open chapter, never more
/// than `maxCharacters` — the reviewer reads the code itself.
package enum ReviewerMapBrief {
    package static let maxCharacters = 6000
    static let summaryLimit = 1200
    static let titleLimit = 120
    static let pathLimit = 160
    static let pathsPerChapter = 3
    static let openChapterPaths = 12
    /// Room kept for the "… N more chapters not listed" line.
    static let moreLineRoom = 48
    /// The noise chapter ("Can skip"): listed as a count only.
    static let collapsedKey = "collapsed"

    package static func render(_ input: ReviewerMapInput) -> String {
        let fileCount = Set(input.chapters.flatMap(\.paths)).count
        var head = ["=== BRANCH MAP ==="]
        head.append("\(input.chapters.count) \(plural(input.chapters.count, "chapter")), \(fileCount) "
            + "\(plural(fileCount, "file")); chapters in reading order, the most dangerous first.")
        let summary = input.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        head.append(summary.isEmpty ? "Summary: none yet." : "Summary: \(clip(summary, summaryLimit))")
        if let key = input.openChapterKey, let open = input.chapters.first(where: { $0.key == key }) {
            head.append("Open on the owner's screen: \(chapterName(open)) — files: "
                + pathList(open.paths, limit: openChapterPaths))
        }
        head.append("Chapters:")
        // Chapters are listed in reading order while they fit, leaving room
        // for the line that counts the rest.
        let lines = input.chapters.map(chapterLine)
        var used = head.joined(separator: "\n").count
        var listed: [String] = []
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            guard used + 1 + line.count + (isLast ? 0 : moreLineRoom) <= maxCharacters else { break }
            listed.append(line)
            used += 1 + line.count
        }
        var all = head + listed
        if listed.count < lines.count { all.append("… \(lines.count - listed.count) more chapters not listed") }
        let text = all.joined(separator: "\n")
        // The head's parts are clipped and the list keeps within the cap, so
        // this never cuts today; it keeps the cap a guarantee if a part grows.
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
    }

    private static func chapterLine(_ chapter: ReviewerMapInput.Chapter) -> String {
        if chapter.key == collapsedKey {
            return "- Can skip (generated, lock and vendored files): \(chapter.paths.count) \(plural(chapter.paths.count, "file"))"
        }
        let level = chapter.level.isEmpty ? "" : "[\(chapter.level)] "
        return "- \(level)\(chapterName(chapter)) — \(chapter.paths.count) \(plural(chapter.paths.count, "file")): "
            + pathList(chapter.paths, limit: pathsPerChapter)
    }

    private static func chapterName(_ chapter: ReviewerMapInput.Chapter) -> String {
        "\(clip(chapter.title, titleLimit)) (\(clip(chapter.key, titleLimit)))"
    }

    private static func pathList(_ paths: [String], limit: Int) -> String {
        guard !paths.isEmpty else { return "none" }
        let listed = paths.prefix(limit).map { clip($0, pathLimit) }.joined(separator: ", ")
        return paths.count > limit ? "\(listed) (+\(paths.count - limit) more)" : listed
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func plural(_ count: Int, _ word: String) -> String {
        count == 1 ? word : word + "s"
    }
}
