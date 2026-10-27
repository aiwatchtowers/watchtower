import Foundation
import GRDB

/// The spec review author loop's reads for the Desktop (board #1121): the
/// finished rounds whose findings line goes into the author's session, and
/// each session's round for its row.
package enum SpecReviewLoopQueries {
    /// A finished reviewer round that hands the author open items.
    package struct PendingRound: Equatable, Sendable {
        package var askID: Int64
        package var sessionID: Int64
        package var round: Int
        /// How many open items the round hands the author.
        package var items: Int
        /// The round's `finished_at`: a new round of the same ask has a new one.
        package var finishedAt: String

        package init(askID: Int64, sessionID: Int64, round: Int, items: Int, finishedAt: String) {
            self.askID = askID
            self.sessionID = sessionID
            self.round = round
            self.items = items
            self.finishedAt = finishedAt
        }
    }

    /// Done rounds of `loop='author'` rows with open items, of open asks
    /// bound to a session, by ask id. Open items that do not read as a JSON
    /// array are left out (nothing to count, nothing to type).
    package static func pending(_ db: Database) throws -> [PendingRound] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT sr.ask_id, a.session_id, sr.round, sr.finished_at,
                   json_array_length(sr.open_items) AS items
            FROM spec_reviews sr
            JOIN owner_asks a ON a.id = sr.ask_id
            WHERE sr.loop = 'author' AND sr.status = 'done'
              AND json_valid(sr.open_items) AND json_type(sr.open_items) = 'array'
              AND json_array_length(sr.open_items) > 0
              AND a.status = 'open' AND a.session_id IS NOT NULL
            ORDER BY sr.ask_id
            """)
        return rows.map {
            PendingRound(askID: $0["ask_id"], sessionID: $0["session_id"], round: $0["round"],
                         items: $0["items"], finishedAt: $0["finished_at"])
        }
    }

    /// An open ask hidden in its author loop, for the stack's Show Now row.
    package struct HiddenLoop: Equatable, Sendable, Identifiable {
        package var askID: Int64
        package var projectID: Int64
        package var title: String
        package var round: Int
        /// `spec` or `plan`.
        package var docType: String
        package var id: Int64 { askID }

        package init(askID: Int64, projectID: Int64, title: String, round: Int, docType: String) {
            self.askID = askID
            self.projectID = projectID
            self.title = title
            self.round = round
            self.docType = docType
        }
    }

    /// Every open ask in a `loop='author'` review, by ask id.
    package static func hidden(_ db: Database) throws -> [HiddenLoop] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT sr.ask_id, a.project_id, a.title, sr.round, a.doc_type
            FROM spec_reviews sr
            JOIN owner_asks a ON a.id = sr.ask_id
            WHERE sr.loop = 'author' AND a.status = 'open'
            ORDER BY sr.ask_id
            """)
        return rows.map {
            HiddenLoop(askID: $0["ask_id"], projectID: $0["project_id"], title: $0["title"],
                       round: $0["round"], docType: $0["doc_type"])
        }
    }

    /// Session id → the round of its open asks' author loops (the highest
    /// when a session has more than one).
    package static func progress(_ db: Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.session_id, MAX(sr.round) AS round
            FROM spec_reviews sr
            JOIN owner_asks a ON a.id = sr.ask_id
            WHERE sr.loop = 'author' AND a.status = 'open' AND a.session_id IS NOT NULL
            GROUP BY a.session_id
            """)
        var out: [Int64: Int] = [:]
        for row in rows { out[row["session_id"]] = row["round"] }
        return out
    }
}
