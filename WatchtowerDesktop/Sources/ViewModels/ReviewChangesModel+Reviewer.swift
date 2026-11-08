import WatchtowerCore

/// What the reviewer beside the diff reads from the round (board #1025,
/// phase 3).
extension ReviewChangesModel {
    /// The reviewer's per-turn map, from the chapters and overview the pane
    /// shows today: a chapter's level is its most serious overview risk.
    ///
    /// Phase-merge seam: once phase 2's map is here (`map` with each
    /// chapter's danger level and the streamed summary), this body reads
    /// `ReviewMap.Chapter` — `level.rawValue`, `paths` — and the summary from
    /// the map's overview state instead. `ReviewerMapInput` and everything
    /// downstream stay as they are.
    var reviewerMapInput: ReviewerMapInput {
        let summary: String = switch overview {
        case let .ready(ready), let .outdated(ready): ready.summary
        case .idle, .loading, .onRequest, .failed: ""
        }
        return ReviewerMapInput(
            chapters: chapters.map { chapter in
                let level = chapterRisks(chapter.key).first.map { "\($0.level.rawValue) risk" } ?? ""
                return ReviewerMapInput.Chapter(key: chapter.key, title: chapter.title, level: level, paths: chapter.paths)
            },
            summary: summary,
            openChapterKey: mode == .deep ? currentChapterKey : nil
        )
    }

    /// Send to author needs an open round to put the design comment in.
    var canSendToAuthor: Bool { round?.status == "open" }
}
