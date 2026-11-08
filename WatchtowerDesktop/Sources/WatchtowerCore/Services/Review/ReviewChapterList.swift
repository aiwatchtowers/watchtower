import Foundation

/// The branch review's chapter list over the map (tech spec §5): its sections, the
/// "N chapters / M files left" counter and the next chapter to read.
package enum ReviewChapterList {
    package struct Section: Equatable, Sendable, Identifiable {
        package enum Kind: Sendable { case dangerous, other, canSkip }

        package var id: Kind { kind }
        package let kind: Kind
        package let chapters: [ReviewMap.Chapter]

        package var title: String {
            switch kind {
            case .dangerous: "Breaking and significant"
            case .other: "Other changes"
            case .canSkip: "Can skip"
            }
        }

        /// "Can skip" starts folded.
        package var foldedByDefault: Bool { kind == .canSkip }
    }

    /// The non-empty sections, in this order: Breaking and significant, Other changes,
    /// Can skip. Chapters keep the map's reading order inside a section.
    package static func sections(_ map: ReviewMap) -> [Section] {
        let dangerous = map.chapters.filter { !$0.isCollapsed && $0.level != .normal }
        let other = map.chapters.filter { !$0.isCollapsed && $0.level == .normal }
        let canSkip = map.chapters.filter(\.isCollapsed)
        return [
            Section(kind: .dangerous, chapters: dangerous),
            Section(kind: .other, chapters: other),
            Section(kind: .canSkip, chapters: canSkip)
        ].filter { !$0.chapters.isEmpty }
    }

    /// Chapters and files left (not Viewed), "Can skip" excluded.
    package static func counter(map: ReviewMap, isViewed: (String) -> Bool) -> (chapters: Int, files: Int) {
        let chapters = map.chapters.filter { !$0.isCollapsed && !done($0, isViewed: isViewed) }.count
        let files = map.files.filter { $0.chapter != ReviewMap.collapsedKey && !isViewed($0.path) }.count
        return (chapters, files)
    }

    /// The key of the first chapter in danger (reading) order with a file not Viewed;
    /// nil when every chapter outside "Can skip" is done.
    package static func next(map: ReviewMap, isViewed: (String) -> Bool) -> String? {
        map.chapters.first { !$0.isCollapsed && !done($0, isViewed: isViewed) }?.key
    }

    /// With one chapter outside "Can skip" (or none) the list is hidden.
    package static func showsList(_ map: ReviewMap) -> Bool {
        map.chapters.filter { !$0.isCollapsed }.count > 1
    }

    private static func done(_ chapter: ReviewMap.Chapter, isViewed: (String) -> Bool) -> Bool {
        chapter.paths.allSatisfy(isViewed)
    }
}
