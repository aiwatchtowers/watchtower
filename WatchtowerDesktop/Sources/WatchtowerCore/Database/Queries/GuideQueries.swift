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
        let sanitized = SearchQueries.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT doc_id, doc_title, anchor, body FROM (
                    SELECT d.id AS doc_id, d.title AS doc_title, c.anchor AS anchor, c.body AS body,
                           ROW_NUMBER() OVER (PARTITION BY d.id ORDER BY kb_fts.rank) AS rn,
                           kb_fts.rank AS rank
                    FROM kb_fts
                    JOIN kb_chunks c ON c.id = kb_fts.rowid
                    JOIN kb_documents d ON d.id = c.doc_id
                    WHERE kb_fts MATCH ? AND d.source = 'guide'
                )
                WHERE rn = 1
                ORDER BY rank
                LIMIT ?
                """,
            arguments: [sanitized, limit]
        )
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

    /// A section with a heading has an anchor and a body that starts with
    /// "<heading>\n"; the lead-in before the first heading has neither.
    private static func heading(body: String, anchor: String) -> String? {
        guard !anchor.isEmpty, let end = body.firstIndex(of: "\n") else { return nil }
        let line = body[..<end].drop { $0 == "#" || $0 == " " }
        return line.isEmpty ? nil : String(line)
    }
}
