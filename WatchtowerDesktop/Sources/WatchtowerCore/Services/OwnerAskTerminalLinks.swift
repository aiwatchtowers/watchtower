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

    /// The hover card's line under the title: "#12 · Check · Waiting for you".
    package static func cardDetail(_ ask: OwnerAsk) -> String {
        ["#\(ask.id)", OwnerAskPresentation.askKindLabel(ask.kind),
         OwnerAskPresentation.askStatusLine(ask, replacedBy: nil)].joined(separator: " · ")
    }
}
