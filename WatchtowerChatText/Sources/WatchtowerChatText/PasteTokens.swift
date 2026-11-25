import Foundation

/// What a paste token stands for (#2065 §6): the pasted text itself, or the file the pasted image was saved to.
public enum PastePayload: Equatable, Sendable {
    case text(String)
    case image(path: String)

    public var kind: PasteKind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }
}

/// Which token a payload stands behind: `[Pasted text #N …]` or `[Image #N]`.
public enum PasteKind: Equatable, Sendable {
    case text, image
}

/// A paste the composer hands to its owner to keep as a token: a long text, or an image's bytes and name.
public enum InlinePaste: Sendable {
    case text(String)
    case image(Data, name: String)
}

/// The inline paste tokens of the Workchat draft, as Claude Code shows them (#2065 §6): `[Image #N]` and
/// `[Pasted text #N +L lines]`. A token is one only while its number has a payload and the draft holds its label (that
/// number and kind) exactly once; the same bracket text typed by hand is plain text (it is neither deleted whole nor
/// expanded). A label held twice is no token at all: the draft text cannot tell the pasted one from a typed copy, so
/// both stay literal and the owner's model drops the payload.
public enum PasteTokens {
    public static func imageLabel(_ n: Int) -> String { "[Image #\(n)]" }

    public static func textLabel(_ n: Int, lines: Int) -> String { "[Pasted text #\(n) +\(lines) lines]" }

    /// A token number above this is never one the composer gave out (a hand-typed `[Image #99999999999]`): the
    /// next number ignores it, so it cannot overflow.
    public static let maxNumber = 1_000_000

    /// The lines of a pasted text; a closing line break adds none.
    public static func lineCount(_ text: String) -> Int {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") { normalized.removeLast() }
        if normalized.isEmpty { return text.isEmpty ? 0 : 1 }
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Group 1: an image token's number; group 2: a text token's.
    private static let token = try? NSRegularExpression(pattern: #"\[(?:Image #(\d+)|Pasted text #(\d+) \+\d+ lines)\]"#)

    private struct Match {
        let range: NSRange
        let number: Int
        let isImage: Bool

        var kind: PasteKind { isImage ? .image : .text }
    }

    private struct Label: Hashable {
        let number: Int
        let isImage: Bool
    }

    /// The matches whose label (number and kind) occurs once in `text`: the only ones that can be tokens.
    private static func singles(in text: String) -> [Match] {
        let all = matches(in: text)
        var counts: [Label: Int] = [:]
        for match in all { counts[Label(number: match.number, isImage: match.isImage), default: 0] += 1 }
        return all.filter { counts[Label(number: $0.number, isImage: $0.isImage)] == 1 }
    }

    private static func matches(in text: String) -> [Match] {
        let string = text as NSString
        let all = token?.matches(in: text, range: NSRange(location: 0, length: string.length)) ?? []
        return all.compactMap { match in
            let image = match.range(at: 1)
            let isImage = image.location != NSNotFound
            guard let number = Int(string.substring(with: isImage ? image : match.range(at: 2))) else { return nil }
            return Match(range: match.range, number: number, isImage: isImage)
        }
    }

    /// The range one Backspace at `utf16Offset` (an empty selection) removes when a token with a payload ends
    /// there: the whole token. nil → an ordinary Backspace.
    public static func deletionRange(backwardFrom utf16Offset: Int, in text: String, live: Set<Int>) -> NSRange? {
        singles(in: text).first { NSMaxRange($0.range) == utf16Offset && live.contains($0.number) }?.range
    }

    /// Kind-aware `deletionRange`: only a token whose number has a payload of the token's own kind is removed whole
    /// (a hand-typed `[Pasted text #1 +3 lines]` beside a live `[Image #1]` is plain text).
    public static func deletionRange(backwardFrom utf16Offset: Int, in text: String, kinds: [Int: PasteKind]) -> NSRange? {
        singles(in: text).first { NSMaxRange($0.range) == utf16Offset && kinds[$0.number] == $0.kind }?.range
    }

    /// The numbers in `kinds` whose token, of that kind, is in `text` exactly once: the payloads a draft still holds.
    public static func liveNumbers(in text: String, kinds: [Int: PasteKind]) -> Set<Int> {
        Set(singles(in: text).filter { kinds[$0.number] == $0.kind }.map(\.number))
    }

    /// The ranges of the live tokens in `text` (a label held once, its number with a payload of the label's kind), in
    /// order: what the Mac field draws as a pill. A typed lookalike and a doubled label are not among them.
    public static func liveRanges(in text: String, kinds: [Int: PasteKind]) -> [NSRange] {
        singles(in: text).filter { kinds[$0.number] == $0.kind }.map(\.range)
    }

    /// The numbers in `kinds` whose label, of that kind, is in `text` at all (once or more): a token the field
    /// inserted, whether or not it still counts as one.
    public static func heldNumbers(in text: String, kinds: [Int: PasteKind]) -> Set<Int> {
        Set(matches(in: text).filter { kinds[$0.number] == $0.kind }.map(\.number))
    }

    /// The numbers of every token-shaped text in `text`, live or typed.
    public static func numbers(in text: String) -> Set<Int> {
        Set(matches(in: text).map(\.number))
    }

    /// `text` with each token whose number has a payload of its kind, and whose label occurs once, replaced: a text
    /// token by its text, an image token by `imagePath(path)`. Every other bracket text stays as it is. An image's
    /// path is kept a word of its own: a space goes between it and a character glued to the token on either side
    /// (`[Image #1][Image #2]`, `look[Image #1]`), unless that is whitespace, a quote or punctuation that closes
    /// after it (`.,;:!?)]}`) or opens before it (`([{`).
    public static func expand(_ text: String, payloads: [Int: PastePayload], imagePath: (String) -> String) -> String {
        let result = NSMutableString(string: text)
        for match in singles(in: text).reversed() {
            let replacement: String
            switch (payloads[match.number], match.isImage) {
            case let (.text(pasted)?, false): replacement = pasted
            case let (.image(path)?, true):
                let before = match.range.location > 0 ? result.character(at: match.range.location - 1) : nil
                let after = NSMaxRange(match.range) < result.length ? result.character(at: NSMaxRange(match.range)) : nil
                let lead = before.map { separates($0, allowed: opensPath) } ?? false ? " " : ""
                let trail = after.map { separates($0, allowed: closesPath) } ?? false ? " " : ""
                replacement = lead + imagePath(path) + trail
            default: continue
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    /// What may touch an image path before it, and after it, without a space.
    private static let opensPath = CharacterSet(charactersIn: "([{\"'").union(.whitespacesAndNewlines)
    private static let closesPath = CharacterSet(charactersIn: ".,;:!?)]}\"'").union(.whitespacesAndNewlines)

    /// A UTF-16 unit next to an image path that needs a space between them (half a surrogate pair always does).
    private static func separates(_ unit: unichar, allowed: CharacterSet) -> Bool {
        Unicode.Scalar(unit).map { !allowed.contains($0) } ?? true
    }
}
