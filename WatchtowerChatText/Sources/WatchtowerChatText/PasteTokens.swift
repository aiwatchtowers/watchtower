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
/// `[Pasted text #N +L lines]`. A token is one only while its number has a payload; the same bracket text typed by
/// hand is plain text (it is neither deleted whole nor expanded).
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
        matches(in: text).first { NSMaxRange($0.range) == utf16Offset && live.contains($0.number) }?.range
    }

    /// Kind-aware `deletionRange`: only a token whose number has a payload of the token's own kind is removed whole
    /// (a hand-typed `[Pasted text #1 +3 lines]` beside a live `[Image #1]` is plain text).
    public static func deletionRange(backwardFrom utf16Offset: Int, in text: String, kinds: [Int: PasteKind]) -> NSRange? {
        matches(in: text).first { NSMaxRange($0.range) == utf16Offset && kinds[$0.number] == $0.kind }?.range
    }

    /// The numbers in `kinds` whose token, of that kind, is in `text`: the payloads a draft still holds.
    public static func liveNumbers(in text: String, kinds: [Int: PasteKind]) -> Set<Int> {
        Set(matches(in: text).filter { kinds[$0.number] == $0.kind }.map(\.number))
    }

    /// The numbers of every token-shaped text in `text`, live or typed.
    public static func numbers(in text: String) -> Set<Int> {
        Set(matches(in: text).map(\.number))
    }

    /// `text` with each token whose number has a payload of its kind replaced: a text token by its text, an image
    /// token by `imagePath(path)`. Every other bracket text stays as it is.
    public static func expand(_ text: String, payloads: [Int: PastePayload], imagePath: (String) -> String) -> String {
        let result = NSMutableString(string: text)
        for match in matches(in: text).reversed() {
            let replacement: String
            switch (payloads[match.number], match.isImage) {
            case let (.text(pasted)?, false): replacement = pasted
            case let (.image(path)?, true): replacement = imagePath(path)
            default: continue
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}
