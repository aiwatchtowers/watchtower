import Foundation

/// A comment's anchor on a document's RENDERED plain text (spec §6.3): the
/// selected quote, up to `contextLength` characters on either side, and the
/// nearest preceding heading. Re-located on every load of a possibly revised
/// file; `locate` returning nil means the thread is outdated.
///
/// Rules (index Review Focus #4): exact matches first, then a
/// whitespace-collapsed match (reflow), then — only for a quote taken from
/// an older rendering of the same text — the legacy separators read as
/// whitespace and the stored context required to match too (see
/// `legacy(_:csv:)`); several candidates are ranked by how
/// much of the stored prefix/suffix still surrounds them; no candidate — or
/// several with none of the original context — is nil. Never fuzzy.
package struct CommentAnchor: Hashable, Sendable {
    package static let contextLength = 64

    package var quote: String
    package var prefix: String
    package var suffix: String
    package var heading: String

    package init(quote: String, prefix: String, suffix: String, heading: String) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.heading = heading
    }

    /// `headings` carry UTF-16 offsets into `text`, in any order.
    package static func make(
        text: String,
        range: Range<String.Index>,
        headings: [(offset: Int, title: String)]
    ) -> Self {
        let start = text.index(range.lowerBound, offsetBy: -contextLength, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: contextLength, limitedBy: text.endIndex) ?? text.endIndex
        let offset = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let heading = headings.filter { $0.offset <= offset }.max { $0.offset < $1.offset }?.title ?? ""
        return Self(
            quote: String(text[range]),
            prefix: String(text[start..<range.lowerBound]),
            suffix: String(text[range.upperBound..<end]),
            heading: heading
        )
    }

    /// - Parameter csv: the anchor was made on a `table` artifact, whose
    ///   anchor text used to be its raw CSV.
    package func locate(in text: String, csv: Bool = false) -> Range<String.Index>? {
        let needle = Array(Self.collapsed(quote).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return nil }
        let exact = Self.exactOccurrences(of: quote, in: text)
        let candidates = exact.isEmpty ? Self.collapsedOccurrences(of: needle, in: text) : exact
        if !candidates.isEmpty { return pick(candidates, in: text) }
        guard let legacy = Self.legacy(quote, csv: csv) else { return nil }
        let legacyNeedle = Array(Self.collapsed(legacy).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !legacyNeedle.isEmpty else { return nil }
        let migrated = Self(quote: legacy, prefix: Self.legacy(prefix, csv: csv) ?? prefix,
                            suffix: Self.legacy(suffix, csv: csv) ?? suffix, heading: heading)
        return migrated.pick(Self.collapsedOccurrences(of: legacyNeedle, in: text), in: text, requireContext: true)
    }

    /// `value` as today's rendering would show it, when it was taken from an
    /// older one (#181): table cells used to be joined with " | " (now one
    /// line each), a rule was "———" (now a blank line), and a `table`
    /// artifact's anchor text was its raw CSV. Nil when nothing changes.
    private static func legacy(_ value: String, csv: Bool) -> String? {
        var legacy = value.replacingOccurrences(of: "———", with: " ").replacingOccurrences(of: " | ", with: "\n")
        if csv { legacy = legacy.replacingOccurrences(of: ",", with: "\n") }
        return legacy == value ? nil : legacy
    }

    // MARK: - Ranking

    /// `requireContext`: even a single candidate must still have some of the
    /// stored prefix/suffix around it — real characters, not just the space
    /// every line ends with (the legacy tier's guard against landing on
    /// look-alike text elsewhere).
    private func pick(
        _ candidates: [Range<String.Index>],
        in text: String,
        requireContext: Bool = false
    ) -> Range<String.Index>? {
        guard candidates.count > 1 || requireContext else { return candidates.first }
        let edge = { (value: String) in requireContext ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value }
        let storedPrefix = Array(edge(Self.collapsed(prefix)))
        let storedSuffix = Array(edge(Self.collapsed(suffix)))
        let scored = candidates.map { candidate -> (Range<String.Index>, Int) in
            let before = Array(edge(Self.collapsed(String(text[..<candidate.lowerBound].suffix(Self.contextLength * 2)))))
            let after = Array(edge(Self.collapsed(String(text[candidate.upperBound...].prefix(Self.contextLength * 2)))))
            let score = Self.commonSuffixLength(before, storedPrefix) + Self.commonPrefixLength(after, storedSuffix)
            return (candidate, score)
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return nil }
        return scored.first { $0.1 == best }?.0
    }

    private static func commonSuffixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        zip(lhs.reversed(), rhs.reversed()).prefix { $0 == $1 }.count
    }

    private static func commonPrefixLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    // MARK: - Matching

    /// Every run of whitespace collapsed to one space; not trimmed.
    private static func collapsed(_ value: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in value {
            if character.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func exactOccurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let hit = text.range(of: needle, options: .literal, range: start..<text.endIndex) {
            found.append(hit)
            start = text.index(after: hit.lowerBound)
        }
        return found
    }

    /// Matches `needle` (already collapsed and trimmed) against `text` with
    /// whitespace runs collapsed, returning ranges in the ORIGINAL text.
    ///
    /// Builds the collapsed text once, then delegates the actual substring
    /// search to `String.range(of:options:.literal,range:)` (the same
    /// stdlib search `exactOccurrences` uses) instead of a hand-rolled
    /// Character-array double loop — the naive version was O(n·m) and took
    /// over a second on a ~1 MB document, tens of seconds on a repetitive
    /// one. `position`/`cursor` walk the collapsed text forward in lockstep
    /// with the search (never backward), so translating every hit back to
    /// `origins` costs O(collapsed length) in total across the whole
    /// search, not per hit.
    private static func collapsedOccurrences(of needle: [Character], in text: String) -> [Range<String.Index>] {
        var collapsedText = ""
        var origins: [String.Index] = []
        var lastWasSpace = false
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                if !lastWasSpace {
                    collapsedText.append(" ")
                    origins.append(index)
                }
                lastWasSpace = true
            } else {
                collapsedText.append(character)
                origins.append(index)
                lastWasSpace = false
            }
        }
        guard origins.count >= needle.count else { return [] }
        let needleString = String(needle)

        var found: [Range<String.Index>] = []
        var searchStart = collapsedText.startIndex
        var cursor = collapsedText.startIndex
        var position = 0
        while searchStart < collapsedText.endIndex,
              let hit = collapsedText.range(of: needleString, options: .literal, range: searchStart..<collapsedText.endIndex) {
            while cursor < hit.lowerBound {
                cursor = collapsedText.index(after: cursor)
                position += 1
            }
            let last = origins[position + needle.count - 1]
            found.append(origins[position]..<text.index(after: last))
            searchStart = collapsedText.index(after: hit.lowerBound)
            cursor = collapsedText.index(after: cursor)
            position += 1
        }
        return found
    }
}
