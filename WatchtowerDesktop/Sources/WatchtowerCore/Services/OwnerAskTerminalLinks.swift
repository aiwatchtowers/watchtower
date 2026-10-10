import Foundation

/// `ask #N` / `ask N` in a workbench session's terminal (board #500): the
/// agent names every ask it files so (the workbench skill's "Asking the
/// owner"), and the owner reaches that ask from the line. The word "ask" in
/// any case, one space, an optional `#`, a whole number; `task #12`,
/// `#12` alone and `ask #12abc` are no link. Whether the number names an
/// ask of the session's own workbench is the caller's lookup. Pure.
package enum OwnerAskTerminalLinks {
    package struct Match: Equatable, Sendable {
        package let askID: Int64
        /// Character offsets in the line (one per terminal cell).
        package let range: Range<Int>
    }

    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])ask #?(\d+)(?![\p{L}\p{N}_])"#, options: [.caseInsensitive])

    package static func matches(in line: String) -> [Match] {
        pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let whole = Range(match.range, in: line), let digits = Range(match.range(at: 1), in: line),
                  let id = Int64(line[digits]) else { return nil }
            let start = line.distance(from: line.startIndex, to: whole.lowerBound)
            return Match(askID: id, range: start..<(start + line[whole].count))
        }
    }

    /// The ask linked at `column` (a character offset) of `line`, or nil.
    package static func askID(inLine line: String, at column: Int) -> Int64? {
        matches(in: line).first { $0.range.contains(column) }?.askID
    }

    /// What a click on a link does: ⌘ opens at once; a plain click opens
    /// once no double click follows (a double or triple click selects as
    /// usual), and never while the program in the terminal reports the
    /// mouse (the click is its own); a click ending a selection opens
    /// nothing.
    package enum Click: Equatable, Sendable {
        case openNow
        case openAfterDoubleClick
        case ignore
    }

    package static func click(clickCount: Int, command: Bool, selectionActive: Bool, mouseReporting: Bool) -> Click {
        guard clickCount == 1, !selectionActive else { return .ignore }
        if command { return .openNow }
        return mouseReporting ? .ignore : .openAfterDoubleClick
    }

    /// The link under the pointer and a generation per hover, so a card
    /// lookup still running when the pointer left (or moved on, or came
    /// back) never shows a second card.
    package struct Hover: Sendable {
        package private(set) var askID: Int64?
        private var generation = 0

        package init() {}

        /// The pointer is over `id`'s link: a token for its lookup, nil
        /// when that link is already hovered.
        package mutating func enter(_ id: Int64) -> Int? {
            guard id != askID else { return nil }
            generation += 1
            askID = id
            return generation
        }

        package mutating func leave() {
            generation += 1
            askID = nil
        }

        /// Whether the lookup `token` started for still answers the hover.
        package func isCurrent(_ token: Int) -> Bool {
            token == generation
        }
    }
}
