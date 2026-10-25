import Foundation

/// The document's `## Decisions` list (spec 2026-10-25 §6), for the spec
/// review's Meaning step: read from the ask's snapshot, the same text the
/// reviewer checked. Pure.
package enum SpecReviewDecisions {
    /// One entry per list item (or paragraph line) of the first section
    /// headed "Decisions", up to the next heading of the same or a higher
    /// level; list markers stripped, an item's continuation lines joined to
    /// it, fenced code skipped. Nil when the document has no such section.
    package static func items(in snapshot: String) -> [String]? {
        var level: Int?
        var items: [String] = []
        var inFence = false
        for line in snapshot.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let heading = heading(trimmed) {
                if let open = level {
                    if heading.level <= open { break }
                    continue
                }
                if heading.title.lowercased() == "decisions" { level = heading.level }
                continue
            }
            guard level != nil, !trimmed.isEmpty else { continue }
            if let item = listItem(trimmed) {
                items.append(item)
            } else if line.first?.isWhitespace == true, let last = items.indices.last {
                items[last] += " " + trimmed
            } else {
                items.append(trimmed)
            }
        }
        return level == nil ? nil : items
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> String? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber), line[line.index(after: dot)...].first == " " else { return nil }
        return line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    }
}
