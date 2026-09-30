import Foundation

/// A word-level diff of two texts, for showing a proposed edit (the
/// `edit_confluence_page` card, spec 2026-09-30 §6). Pure.
///
/// Tokens are runs of whitespace and runs of non-whitespace, so every byte of
/// both texts lands in exactly one segment: the `.same` + `.removed` segments
/// rebuild `before`, the `.same` + `.added` segments rebuild `after`. The
/// common head and tail are trimmed first; the changed middle is aligned by a
/// longest-common-subsequence over tokens, bounded by `maxCells` — a middle
/// too large for the table is shown as "all of this replaced by all of
/// that", which is still exact, never slow.
package enum WordDiff {
    package enum Kind: Sendable {
        case same, removed, added
    }

    package struct Segment: Equatable, Sendable {
        package let kind: Kind
        package let text: String

        package init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// The LCS table's cell budget (tokens × tokens of the changed middle).
    /// With `UInt16` cells this is 8 MB at most; the smaller side is then at
    /// most 2 000 tokens, so an LCS length always fits the cell type.
    package static let maxCells = 4_000_000

    package static func diff(before: String, after: String) -> [Segment] {
        let old = tokens(before)
        let new = tokens(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        var ops = old[0..<prefix].map { Segment(kind: .same, text: $0) }
        ops += middle(Array(old[prefix..<(old.count - suffix)]), Array(new[prefix..<(new.count - suffix)]))
        ops += old[(old.count - suffix)...].map { Segment(kind: .same, text: $0) }
        return coalesce(ops)
    }

    // MARK: - Tokens

    private static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentIsSpace = false
        for char in text {
            if !current.isEmpty, char.isWhitespace != currentIsSpace {
                out.append(current)
                current = ""
            }
            currentIsSpace = char.isWhitespace
            current.append(char)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Alignment

    /// Token-level ops for the changed middle (no common head or tail).
    private static func middle(_ old: [String], _ new: [String]) -> [Segment] {
        let removedAll = old.map { Segment(kind: .removed, text: $0) }
        let addedAll = new.map { Segment(kind: .added, text: $0) }
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= maxCells else {
            return removedAll + addedAll
        }
        let table = lcsTable(old, new)
        let width = new.count + 1
        var ops: [Segment] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                ops.append(Segment(kind: .same, text: old[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                ops.append(Segment(kind: .removed, text: old[i]))
                i += 1
            } else {
                ops.append(Segment(kind: .added, text: new[j]))
                j += 1
            }
        }
        ops += old[i...].map { Segment(kind: .removed, text: $0) }
        ops += new[j...].map { Segment(kind: .added, text: $0) }
        return ops
    }

    /// `table[i * (m + 1) + j]` = LCS length of `old[i...]` and `new[j...]`.
    private static func lcsTable(_ old: [String], _ new: [String]) -> [UInt16] {
        let n = old.count
        let m = new.count
        let width = m + 1
        var table = [UInt16](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = old[i] == new[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        return table
    }

    // MARK: - Presentation

    /// An unchanged run, or a change: what was removed and what was added
    /// there (either may be empty, not both).
    private enum Block {
        case same(String)
        case change(removed: String, added: String)

        var isReplacement: Bool {
            if case let .change(removed, added) = self { return !removed.isEmpty && !added.isEmpty }
            return false
        }
    }

    /// Merges token ops into segments: each unchanged run becomes one
    /// `.same`, each change one `.removed` then one `.added`. A whitespace-
    /// only unchanged run between two replacements is folded into them, so
    /// "Friday morning" → "Monday evening" reads as one replaced phrase
    /// rather than two fragments around a lone kept space.
    private static func coalesce(_ ops: [Segment]) -> [Segment] {
        var blocks: [Block] = []
        for op in ops {
            blocks = appending(op, to: blocks)
        }
        return foldSpaces(blocks).flatMap(segments)
    }

    private static func appending(_ op: Segment, to blocks: [Block]) -> [Block] {
        var blocks = blocks
        switch (op.kind, blocks.last) {
        case let (.same, .same(text)?):
            blocks[blocks.count - 1] = .same(text + op.text)
        case (.same, _):
            blocks.append(.same(op.text))
        case let (.removed, .change(removed, added)?):
            blocks[blocks.count - 1] = .change(removed: removed + op.text, added: added)
        case let (.added, .change(removed, added)?):
            blocks[blocks.count - 1] = .change(removed: removed, added: added + op.text)
        case (.removed, _):
            blocks.append(.change(removed: op.text, added: ""))
        case (.added, _):
            blocks.append(.change(removed: "", added: op.text))
        }
        return blocks
    }

    private static func foldSpaces(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if case let .same(space) = block, space.allSatisfy(\.isWhitespace),
               let previous = out.last, previous.isReplacement,
               index + 1 < blocks.count, blocks[index + 1].isReplacement,
               case let .change(r1, a1) = previous, case let .change(r2, a2) = blocks[index + 1] {
                out[out.count - 1] = .change(removed: r1 + space + r2, added: a1 + space + a2)
                index += 2
                continue
            }
            out.append(block)
            index += 1
        }
        return out
    }

    private static func segments(_ block: Block) -> [Segment] {
        switch block {
        case let .same(text):
            return [Segment(kind: .same, text: text)]
        case let .change(removed, added):
            var out: [Segment] = []
            if !removed.isEmpty { out.append(Segment(kind: .removed, text: removed)) }
            if !added.isEmpty { out.append(Segment(kind: .added, text: added)) }
            return out
        }
    }
}
