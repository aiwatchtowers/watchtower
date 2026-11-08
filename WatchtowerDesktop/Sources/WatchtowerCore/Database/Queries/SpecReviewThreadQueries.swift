import Foundation
import GRDB

/// Reads for spec review threads (spec 2026-11-08 §3): the review chain's
/// root (the thread key's middle part), the thread agent's questions to the
/// author and the findings the owner added from a thread — both written by
/// Go only (`spec_review_questions`, `spec_review_thread_findings`) — and how
/// many messages each thread holds, for its folded "thread · N" line.
package enum SpecReviewThreadQueries {
    /// The walk along `previous_ask_id` stops this deep, as Go's
    /// `specReviewChainMaxDepth`, so a cycle (which no writer makes) still ends.
    package static let chainMaxDepth = 100

    /// The first ask of `askID`'s review chain (the asks linked by
    /// `owner_asks.previous_ask_id`), as Go's `SpecReviewChain` walks it. An
    /// ask with no previous ask is its own root; so is an unknown one.
    package static func chainRoot(_ db: Database, askID: Int64) throws -> Int64 {
        let root = try Int64.fetchOne(db, sql: """
            WITH RECURSIVE chain(id, prev, depth) AS (
                SELECT id, previous_ask_id, 0 FROM owner_asks WHERE id = ?
                UNION ALL
                SELECT a.id, a.previous_ask_id, c.depth + 1 FROM owner_asks a
                    JOIN chain c ON a.id = c.prev
                WHERE c.depth < ?
            )
            SELECT id FROM chain ORDER BY depth DESC LIMIT 1
            """, arguments: [askID, chainMaxDepth])
        return root ?? askID
    }

    /// The questions of these threads (conversation keys), oldest first.
    package static func questions(_ db: Database, threads: [String]) throws -> [SpecReviewQuestionRow] {
        guard !threads.isEmpty else { return [] }
        let marks = databaseQuestionMarks(count: threads.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, ask_id, thread, item_key, question, answer, state
            FROM spec_review_questions WHERE thread IN (\(marks)) ORDER BY id
            """, arguments: StatementArguments(threads))
        return rows.map { row in
            SpecReviewQuestionRow(
                id: row["id"],
                askID: row["ask_id"],
                thread: row["thread"],
                itemKey: row["item_key"],
                question: row["question"],
                answer: row["answer"],
                state: .init(raw: row["state"])
            )
        }
    }

    /// The findings the owner added to this ask from a thread, in the order
    /// they were added, each `.added` under its row's key. A row whose JSON
    /// this build cannot read is left out rather than blanking the screen.
    package static func threadFindings(_ db: Database, askID: Int64) throws -> [SpecReviewProposedFinding] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT item_key, finding FROM spec_review_thread_findings
            WHERE ask_id = ? ORDER BY created_at, item_key
            """, arguments: [askID])
        return rows.compactMap { row in
            let key: String = row["item_key"]
            let json: String = row["finding"]
            guard var finding = try? JSONDecoder().decode(SpecReviewProposedFinding.self, from: Data(json.utf8)) else {
                return nil
            }
            finding.key = key
            finding.status = .added(key: key)
            return finding
        }
    }

    /// Thread key → its owner's and assistant's finished messages; a key
    /// with no conversation (or no message yet) is absent.
    package static func messageCounts(_ db: Database, contextIDs: [String]) throws -> [String: Int] {
        guard !contextIDs.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: contextIDs.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.context_id AS context_id, COUNT(m.id) AS n
            FROM chat_conversations c
            JOIN chat_messages m ON m.conversation_id = c.id
            WHERE c.context_type = ? AND c.context_id IN (\(marks))
              AND m.role IN ('user', 'assistant') AND m.status = 'complete'
            GROUP BY c.context_id
            """, arguments: StatementArguments([SpecReviewThreadKey.contextType] + contextIDs))
        var out: [String: Int] = [:]
        for row in rows {
            let id: String = row["context_id"]
            out[id, default: 0] += row["n"] as Int
        }
        return out
    }
}
