import Foundation
import GRDB

/// One user-guide page that matches a query.
package struct GuideHit: Equatable {
    package let path: String       // relative to docs/guide/
    package let title: String
    package let heading: String?   // display only; the URL uses the chunk anchor
    package let url: URL
}

package enum GuideQueries {
    /// Top guide pages for `query`: one hit per page, ordered by the page's
    /// best-ranked chunk. Reads the knowledge index (`source = 'guide'`).
    package static func search(_ db: Database, query: String, limit: Int = 3) throws -> [GuideHit] {
        let terms = SearchQueries.sanitizeFTS5Query(query)
        guard !terms.isEmpty else { return [] }
        // Every term first; a natural question rarely has all its words on one
        // page, so an empty result retries with any term (mirrors Go BuildMatch).
        var rows = try fetch(db, match: terms, limit: limit)
        if rows.isEmpty, terms.contains("\" \"") {
            rows = try fetch(db, match: terms.replacingOccurrences(of: "\" \"", with: "\" OR \""), limit: limit)
        }
        return rows.map { row in
            let docID: String = row["doc_id"]
            let path = docID.hasPrefix("guide:") ? String(docID.dropFirst(6)) : docID
            let anchor: String = row["anchor"]
            return GuideHit(
                path: path,
                title: row["doc_title"],
                heading: heading(body: row["body"], anchor: anchor),
                url: GuideLinks.url(path: path, anchor: anchor)
            )
        }
    }

    private static func fetch(_ db: Database, match: String, limit: Int) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT doc_id, doc_title, anchor, body, score, chunk_id FROM (
                    SELECT *, ROW_NUMBER() OVER (PARTITION BY doc_id ORDER BY score, chunk_id) AS rn FROM (
                        SELECT d.id AS doc_id, d.title AS doc_title, c.anchor AS anchor, c.body AS body,
                               bm25(kb_fts, 4.0, 1.0, 2.0) AS score, c.id AS chunk_id
                        FROM kb_fts
                        JOIN kb_chunks c ON c.id = kb_fts.rowid
                        JOIN kb_documents d ON d.id = c.doc_id
                        WHERE kb_fts MATCH ? AND d.source = 'guide'
                    )
                )
                WHERE rn = 1
                ORDER BY score, chunk_id
                LIMIT ?
                """,
            arguments: [match, limit]
        )
    }

    /// A section with a heading has an anchor and a body that starts with
    /// "<heading>\n"; the lead-in before the first heading has neither.
    private static func heading(body: String, anchor: String) -> String? {
        guard !anchor.isEmpty, let end = body.firstIndex(of: "\n") else { return nil }
        let line = body[..<end].drop { $0 == "#" || $0 == " " }
        return line.isEmpty ? nil : String(line)
    }
}
