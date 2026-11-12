import Foundation

/// The Inbox list's search (spec "The list"): the rows already loaded
/// whose title or preview holds the query. Pure.
package enum InboxListFilter {
    /// `content`'s title or preview holds the trimmed `query`, ignoring case
    /// and diacritics ("cafe" finds "Café"); an empty query matches every row.
    package static func matches(_ content: InboxRowContent, query: String) -> Bool {
        let query = trimmed(query)
        guard !query.isEmpty else { return true }
        return content.title.localizedStandardContains(query) || content.preview.localizedStandardContains(query)
    }

    /// `sections` with only the rows that match; a section left with none
    /// is dropped, the others keep their title and count.
    package static func apply(_ sections: [InboxListSection], query: String) -> [InboxListSection] {
        let query = trimmed(query)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter { matches($0.content, query: query) }
            return rows.isEmpty ? nil
                : InboxListSection(id: section.id, title: section.title, rows: rows, count: section.count)
        }
    }

    /// The query as searched: without its leading and trailing whitespace.
    package static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
