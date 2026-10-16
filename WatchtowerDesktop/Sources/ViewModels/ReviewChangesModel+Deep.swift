import Foundation
import GRDB
import WatchtowerCore

/// Deep mode of the Changes pane (board #328, spec §10): mode and phase, the
/// mechanical chapters, lens checklists, the Wrap-up intent marks and the
/// active-time pace. All writes are the Desktop's rows (`ReviewQueries`); a
/// round that was sent is read-only.
extension ReviewChangesModel {
    /// Wrap-up marks live under this chapter key and the `intent` lens.
    private static let wrapupChapter = "wrapup"
    private static let intentLens = "intent"
    /// Unsaved active seconds that trigger a save.
    private static let saveEverySeconds = 30

    // MARK: - Mode, phase, chapter

    func setMode(_ m: Mode) throws {
        try run {
            try saveState(mode: m, phase: phase, chapterKey: currentChapterKey)
            mode = m
        }
    }

    func setPhase(_ p: ReviewPhase) throws {
        try run {
            try saveState(mode: mode, phase: p, chapterKey: currentChapterKey)
            phase = p
        }
    }

    /// Makes `key` the current chapter and opens its first non-collapsed file.
    func selectChapter(_ key: String) async throws {
        guard let chapter = chapters.first(where: { $0.key == key }) else { return }
        try run {
            // A sent round only moves on screen; the position is saved while it is open.
            if round?.status == "open" { try saveState(mode: mode, phase: phase, chapterKey: key) }
            currentChapterKey = key
        }
        let first = chapter.paths.first { path in files.first { $0.path == path }?.collapsedReason == nil } ?? chapter.paths.first
        if let first { await select(first) }
    }

    /// Chapters from the current view's files, and a current chapter that
    /// still exists (the first one otherwise); checks of a vanished chapter stay in the DB.
    func refreshChapters() {
        chapters = ReviewChapters.mechanical(files)
        if let key = currentChapterKey, chapters.contains(where: { $0.key == key }) { return }
        currentChapterKey = chapters.first?.key
    }

    // MARK: - Checks and comments

    func checks(forChapter key: String) -> [ReviewCheck] {
        checks.filter { $0.chapterKey == key }
    }

    func setCheck(chapterKey: String, lens: String, itemKey: String, checked: Bool) throws {
        try run {
            let info = try openRound()
            try db.write {
                try ReviewQueries.setCheck($0, roundID: info.id, chapterKey: chapterKey, lens: lens, itemKey: itemKey,
                                           state: checked ? .checked : nil)
            }
            try reloadChecks()
        }
    }

    /// A design comment for a checklist question, and the question marked `commented`.
    func commentOnCheck(chapterKey: String, lens: String, item: ReviewLens.Item, body: String) throws {
        try run {
            let info = try openRound()
            try db.write { db in
                _ = try Self.addDesign(db, info: info, body: body, lens: lens)
                try ReviewQueries.setCheck(db, roundID: info.id, chapterKey: chapterKey, lens: lens, itemKey: item.key,
                                           state: .commented)
            }
            try reloadComments()
            try reloadChecks()
        }
    }

    func addDesignComment(body: String, lens: String) throws {
        try run {
            let info = try openRound()
            try db.write { _ = try Self.addDesign($0, info: info, body: body, lens: lens) }
            try reloadComments()
        }
    }

    /// Marks a Wrap-up intent item; partial and not done also leave a design comment.
    func markIntent(_ item: ReviewIntentItem, state: ReviewCheck.State, note: String) throws {
        try run {
            let info = try openRound()
            try db.write { db in
                if state == .partial || state == .notDone {
                    let body = ReviewWrapUp.intentCommentBody(partial: state == .partial, item: item, note: note)
                    _ = try Self.addDesign(db, info: info, body: body, lens: Self.intentLens)
                }
                try ReviewQueries.setCheck(db, roundID: info.id, chapterKey: Self.wrapupChapter, lens: Self.intentLens,
                                           itemKey: item.key, state: state)
            }
            try reloadComments()
            try reloadChecks()
        }
    }

    // MARK: - Active time

    func noteInteraction(at date: Date = .now) {
        pace.noteInteraction(at: date)
    }

    func tick(at date: Date = .now, isKey: Bool) {
        pace.tick(at: date, isKey: isKey)
        if pace.activeSeconds - savedActiveSeconds >= Self.saveEverySeconds { flushState() }
    }

    /// Saves the position and active time now (on disappear and before Send).
    func flushState() {
        guard round?.status == "open" else { return }
        do {
            try saveState(mode: mode, phase: phase, chapterKey: currentChapterKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func openRound() throws -> ReviewRoundInfo {
        guard let info = round else { throw ModelError.noRound }
        guard info.status == "open" else { throw ModelError.roundClosed }
        return info
    }

    private func saveState(mode: Mode, phase: ReviewPhase, chapterKey: String?) throws {
        let info = try openRound()
        let seconds = pace.activeSeconds
        let saved = try db.write {
            try ReviewQueries.saveRoundState($0, roundID: info.id, mode: mode.rawValue, phase: phase,
                                             chapterKey: chapterKey ?? "", activeSeconds: seconds)
        }
        guard saved else { throw ModelError.roundClosed }
        savedActiveSeconds = seconds
    }

    private func reloadChecks() throws {
        guard let info = round else { return }
        checks = try db.read { try ReviewQueries.checks($0, roundID: info.id) }
    }

    private static func addDesign(_ db: Database, info: ReviewRoundInfo, body: String, lens: String) throws -> Int64 {
        try ReviewQueries.addDraft(db, roundID: info.id, path: nil, side: "new", startLine: 0, endLine: 0,
                                   anchor: CommentAnchor(quote: "", prefix: "", suffix: "", heading: ""),
                                   treeSHA: info.treeSha, body: body, lens: lens)
    }
}
