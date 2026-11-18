import Foundation
import GRDB

/// The owner's morning feedback on the journal (spec §8.3, §10): the only
/// writers of `watchman_items.feedback`, `feedback_text`, `feedback_at`,
/// `check_done_at`, `owner_done_at` and `correction_sent_at` (Go never
/// writes them). Learning reads an OK'd or
/// corrected twin decision as a precedent (WATCHMAN-03), so OK and
/// Correct… take only a finished twin decision; a second tap, or an item
/// already given feedback, writes nothing. Each returns whether it wrote.
package enum WatchmanFeedbackQueries {
    /// A finished twin decision the owner has not judged yet: what OK and
    /// Correct… may write on. A parked, handed or owner-first item and a
    /// check are not the twin's decisions.
    private static let undecidedTwinDecision = """
        id = ? AND feedback = '' AND state = 'done' AND kind != 'check'
            AND outcome IN ('answered', 'approved', 'changes')
        """

    /// OK: the twin's decision stands and becomes a precedent.
    @discardableResult
    package static func ok(_ db: Database, itemID: Int64, now: Date = Date()) throws -> Bool {
        try db.execute(sql: """
            UPDATE watchman_items SET feedback = 'ok', feedback_at = ?
            WHERE \(undecidedTwinDecision)
            """, arguments: [AutomationDates.format(now), itemID])
        return db.changesCount > 0
    }

    /// Correct…: the owner's own decision, stored as written (trimmed);
    /// learning weighs it above an OK. A blank correction is refused.
    @discardableResult
    package static func correct(_ db: Database, itemID: Int64, text: String, now: Date = Date()) throws -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WatchmanFeedbackError.blankCorrection }
        try db.execute(sql: """
            UPDATE watchman_items SET feedback = 'corrected', feedback_text = ?, feedback_at = ?
            WHERE \(undecidedTwinDecision)
            """, arguments: [text, AutomationDates.format(now), itemID])
        return db.changesCount > 0
    }

    /// A check Watchman passed on has been run: it leaves Checks nobody ran.
    @discardableResult
    package static func checkDone(_ db: Database, itemID: Int64, now: Date = Date()) throws -> Bool {
        try db.execute(sql: """
            UPDATE watchman_items SET check_done_at = ?
            WHERE id = ? AND kind = 'check' AND check_done_at IS NULL
            """, arguments: [AutomationDates.format(now), itemID])
        return db.changesCount > 0
    }

    /// Mark done on a waiting item (parked, handed, a guard denial): it
    /// leaves Waiting for you. Not feedback: learning never reads it.
    @discardableResult
    package static func ownerDone(_ db: Database, itemID: Int64, now: Date = Date()) throws -> Bool {
        try db.execute(sql: """
            UPDATE watchman_items SET owner_done_at = ?
            WHERE id = ? AND owner_done_at IS NULL AND state = 'done' AND outcome IN ('parked', 'handed')
            """, arguments: [AutomationDates.format(now), itemID])
        return db.changesCount > 0
    }

    /// The owner's correction reached a session (typed into it, or a new
    /// session started with it): it is no longer `Not sent` after a relaunch.
    @discardableResult
    package static func correctionSent(_ db: Database, itemID: Int64, now: Date = Date()) throws -> Bool {
        try db.execute(sql: """
            UPDATE watchman_items SET correction_sent_at = ?
            WHERE id = ? AND feedback = 'corrected' AND correction_sent_at IS NULL
            """, arguments: [AutomationDates.format(now), itemID])
        return db.changesCount > 0
    }
}

package enum WatchmanFeedbackError: Error, Equatable {
    /// Correct… with nothing written: no decision to learn.
    case blankCorrection
}

/// One of the owner's feedback writes, as a value (the journal's actions).
package enum WatchmanFeedbackWrite: Equatable, Sendable {
    case ok(Int64)
    case correct(Int64, String)
    case checkDone(Int64)
    case ownerDone(Int64)
    case correctionSent(Int64)

    /// Runs it; whether it wrote.
    package func apply(_ db: Database, now: Date = Date()) throws -> Bool {
        switch self {
        case let .ok(id): try WatchmanFeedbackQueries.ok(db, itemID: id, now: now)
        case let .correct(id, text): try WatchmanFeedbackQueries.correct(db, itemID: id, text: text, now: now)
        case let .checkDone(id): try WatchmanFeedbackQueries.checkDone(db, itemID: id, now: now)
        case let .ownerDone(id): try WatchmanFeedbackQueries.ownerDone(db, itemID: id, now: now)
        case let .correctionSent(id): try WatchmanFeedbackQueries.correctionSent(db, itemID: id, now: now)
        }
    }
}
