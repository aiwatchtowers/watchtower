import WatchtowerCore

/// What the reviewer beside the diff reads from the round (board #1025,
/// phase 3).
extension ReviewChangesModel {
    /// The reviewer's per-turn map: the round's `ReviewMap` chapters in
    /// reading order with their danger level, the overview's summary and the
    /// chapter open in Deep. Until the map is in (loading or failed), the
    /// pane's chapters with their most serious overview risk as the level.
    var reviewerMapInput: ReviewerMapInput {
        let summary: String = switch overview {
        case let .ready(ready), let .outdated(ready): ready.summary
        case .idle, .loading, .onRequest, .failed: ""
        }
        let mapChapters: [ReviewerMapInput.Chapter]
        if case let .ready(ready) = map {
            mapChapters = ready.chapters.map { chapter in
                ReviewerMapInput.Chapter(key: chapter.key, title: chapter.title, level: chapter.level.rawValue,
                                         paths: chapter.paths)
            }
        } else {
            mapChapters = chapters.map { chapter in
                let level = chapterRisks(chapter.key).first.map { "\($0.level.rawValue) risk" } ?? ""
                return ReviewerMapInput.Chapter(key: chapter.key, title: chapter.title, level: level, paths: chapter.paths)
            }
        }
        return ReviewerMapInput(
            chapters: mapChapters,
            summary: summary,
            openChapterKey: mode == .deep ? currentChapterKey : nil
        )
    }

    /// Send to author needs an open round to put the design comment in.
    var canSendToAuthor: Bool { round?.status == "open" }
}
