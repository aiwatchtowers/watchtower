import Foundation

/// What changed between a review re-round's previous and current document
/// snapshots (spec 2026-10-03 Part 8, "Показать дифф"): a line diff plus the
/// Markdown headings whose sections were added, removed or changed. Pure.
package struct OwnerAskSnapshotDiff: Equatable, Sendable {
    package enum Line: Equatable, Sendable {
        case same(String)
        case added(String)
        case removed(String)
    }

    package let lines: [Line]
    /// Headings only in the current snapshot, in its order.
    package let addedHeadings: [String]
    /// Headings only in the previous snapshot, in its order.
    package let removedHeadings: [String]
    /// Headings in both whose section text differs, in the current order.
    package let changedHeadings: [String]

    package var isIdentical: Bool {
        lines.allSatisfy { if case .same = $0 { true } else { false } }
    }

    package init(previous: String, current: String) {
        let old = Self.split(previous)
        let new = Self.split(current)
        lines = Self.diff(old, new)
        let before = Self.sections(old)
        let after = Self.sections(new)
        let beforeKeys = Set(before.map(\.key))
        let afterKeys = Set(after.map(\.key))
        addedHeadings = after.filter { !beforeKeys.contains($0.key) }.map(\.key.title)
        removedHeadings = before.filter { !afterKeys.contains($0.key) }.map(\.key.title)
        let beforeBodies = Dictionary(before.map { ($0.key, $0.body) }) { first, _ in first }
        changedHeadings = after.compactMap { section in
            guard let body = beforeBodies[section.key], body != section.body else { return nil }
            return section.key.title
        }
    }

    private static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// Lines in reading order, a removal before the addition that replaces it.
    private static func diff(_ old: [String], _ new: [String]) -> [Line] {
        let changes = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in changes {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                out.append(.removed(old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                out.append(.added(new[j]))
                j += 1
            } else {
                out.append(.same(new[j]))
                i += 1
                j += 1
            }
        }
        return out
    }

    /// A heading's title with its occurrence among same-titled headings, so
    /// two "Notes" sections are told apart.
    private struct SectionKey: Hashable {
        let title: String
        let occurrence: Int
    }

    /// Each ATX heading (outside code fences) and the lines up to the next
    /// heading. Text before the first heading belongs to no section.
    private static func sections(_ lines: [String]) -> [(key: SectionKey, body: [String])] {
        var out: [(key: SectionKey, body: [String])] = []
        var seen: [String: Int] = [:]
        // The open fence's character and length: only a run of the same
        // character, at least as long, closes it (CommonMark).
        var fence: (char: Character, count: Int)?
        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            // Four spaces or a tab make an indented code line: never a fence or a heading.
            let markdown = indent < 4 && line.dropFirst(indent).first != "\t"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if markdown, let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }.count
                if let open = fence {
                    if first == open.char, run >= open.count, trimmed.allSatisfy({ $0 == first }) { fence = nil }
                } else if run >= 3 {
                    fence = (first, run)
                }
            }
            if fence == nil, markdown, let title = heading(trimmed) {
                let occurrence = seen[title, default: 0]
                seen[title] = occurrence + 1
                out.append((SectionKey(title: title, occurrence: occurrence), []))
            } else if !out.isEmpty {
                out[out.count - 1].body.append(line)
            }
        }
        return out
    }

    /// `# Title` … `###### Title`; a closing run of hashes after a space is
    /// dropped (`## C#` keeps its hash).
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        let closing = title.reversed().prefix { $0 == "#" }.count
        if closing == title.count {
            title = ""
        } else if closing > 0, title.dropLast(closing).last?.isWhitespace == true {
            title = title.dropLast(closing).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? nil : title
    }
}
