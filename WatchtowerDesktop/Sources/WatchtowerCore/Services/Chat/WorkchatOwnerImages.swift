import Foundation

/// The images in an owner's Workchat line, read off its text for display only: a pasted image goes to the agent as
/// its saved file's path (`WorkchatOutgoing.quoted`, in place of its `[Image #N]` token), a dropped image file as its
/// path on a line of its own. The bubble shows each as a thumbnail or a chip and the text without those paths; what
/// was sent, the feed's entry and the echo match are untouched.
///
/// A path counts when it is absolute, ends in an image extension and stands as a whole token (bare, or in double
/// quotes with `\"` and `\\` escaped; punctuation around it is the owner's text), and either lies in Watchtower's own
/// attachments folder (`WorkchatAttachmentStore.root`: a paste, inline or on its own line — the only file whose
/// contents the bubble reads, as a thumbnail) or stands on a line of its own (a dropped or picked image anywhere
/// else: a chip with its name, never read nor even looked up, so no folder Watchtower has no access to asks for it).
/// Any other image path — one named mid-sentence outside the attachments folder — is the owner's prose and stays
/// text. Pure: no file is touched here.
package struct WorkchatOwnerImages: Equatable, Sendable {
    package struct ImageFile: Equatable, Hashable, Sendable {
        package let path: String
        /// In the attachments folder: drawn as a thumbnail (a chip when gone or not decodable). Anywhere else: a
        /// chip only, its file never read.
        package let isAttachment: Bool

        package init(path: String, isAttachment: Bool) {
            self.path = path
            self.isAttachment = isAttachment
        }

        package var name: String { (path as NSString).lastPathComponent }
    }

    /// The text to show: the image paths taken out, a line left empty by them dropped, and an image marker line
    /// (Go's `[image]`, Claude Code's `[Image #N]`) dropped when an image stands for it. Unchanged when no image was
    /// found.
    package let text: String
    /// The images in order of first appearance, each path once.
    package let images: [ImageFile]

    package static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic"]

    /// `text` split into what the bubble shows and its images; `attachmentsRoot` is the attachments folder's path
    /// (nil: none known, so every image is a chip).
    package static func split(_ text: String, attachmentsRoot: String?) -> Self {
        guard text.contains("/") else { return Self(text: text, images: []) }
        let folder = attachmentsRoot.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var images: [ImageFile] = []
        var lines: [String] = []
        // A line ending in `\r\n` stands alone the same as one ending in `\n`.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let tokens = pathTokens(in: line)
            let alone = tokens.count == 1 && tokens[0].raw == line.trimmingCharacters(in: .whitespaces)
            let found = tokens.compactMap { token in
                image(token.path, alone: alone, attachments: folder).map { (token, $0) }
            }
            guard !found.isEmpty else {
                lines.append(line)
                continue
            }
            for (_, image) in found where !images.contains(where: { $0.path == image.path }) { images.append(image) }
            var kept = line
            // Paths glued end to end leave as one.
            var runs: [Range<String.Index>] = []
            for (token, _) in found {
                if let last = runs.last, last.upperBound == token.range.lowerBound {
                    runs[runs.count - 1] = last.lowerBound..<token.range.upperBound
                } else {
                    runs.append(token.range)
                }
            }
            for run in runs.reversed() {
                let cut = removal(of: run, in: line)
                kept.replaceSubrange(cut.range, with: cut.joint)
            }
            let tidy = kept.split { $0 == " " || $0 == "\t" }.joined(separator: " ")
            if !tidy.isEmpty { lines.append(tidy) }
        }
        guard !images.isEmpty else { return Self(text: text, images: []) }
        lines.removeAll { WorkchatOutgoing.isImageMarker($0.trimmingCharacters(in: .whitespaces)) }
        let shown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(text: shown, images: images)
    }

    private static func image(_ path: String, alone: Bool, attachments folder: String?) -> ImageFile? {
        guard path.hasPrefix("/"),
              imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        if let folder, isInside(path, folder) { return ImageFile(path: path, isAttachment: true) }
        return alone ? ImageFile(path: path, isAttachment: false) : nil
    }

    /// `path` lies under `folder` (ending in `/`) by its text alone: a `.` or `..` component, which could lead out of
    /// it, never counts.
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        guard path.hasPrefix(folder) else { return false }
        return !path.dropFirst(folder.count).split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    private struct Token {
        let range: Range<String.Index>
        let raw: Substring
        let path: String
    }

    /// Punctuation that may open before a path and stays text: `(/…/a.png)`.
    private static let openers: Set<Character> = ["(", "[", "{"]
    /// Punctuation that may close after a path and stays text: `see /…/a.png.`, `"/…/a b.png",`.
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// What leaves the line with a path, and what takes its place: the path, the brackets around it when they held
    /// only it, and the spaces before it when punctuation follows (`see /…/a.png.` reads `see.`); a space otherwise.
    private static func removal(
        of range: Range<String.Index>,
        in line: String
    ) -> (range: Range<String.Index>, joint: String) {
        var lower = range.lowerBound
        var upper = range.upperBound
        if lower > line.startIndex, upper < line.endIndex,
           let close = pairs[line[line.index(before: lower)]], line[upper] == close {
            lower = line.index(before: lower)
            upper = line.index(after: upper)
        }
        guard upper < line.endIndex, closers.contains(line[upper]) else { return (lower..<upper, " ") }
        while lower > line.startIndex, line[line.index(before: lower)].isWhitespace {
            lower = line.index(before: lower)
        }
        return (lower..<upper, "")
    }

    /// The whole-token absolute paths of one line: bare (`/…` up to whitespace, closing punctuation left out) or
    /// double-quoted with `\"` and `\\` escaped (`"/…"` followed by whitespace, closing punctuation or the end), each
    /// starting the line or after whitespace, past any opening bracket.
    private static func pathTokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            let atBoundary = index == line.startIndex || line[line.index(before: index)].isWhitespace
            guard atBoundary else {
                index = line.index(after: index)
                continue
            }
            let start = line[index...].firstIndex { !openers.contains($0) } ?? line.endIndex
            let found = start == line.endIndex ? []
                : quotedToken(in: line, at: start).map { [$0] } ?? bareTokens(in: line, at: start)
            if let last = found.last {
                tokens += found
                index = last.range.upperBound
            } else {
                index = line.index(after: index)
            }
        }
        return tokens
    }

    /// `index` ends a token: the end or whitespace, once any closing punctuation is skipped.
    private static func endsToken(_ line: String, at index: String.Index) -> Bool {
        let rest = line[index...].drop { closers.contains($0) }
        return rest.first.map(\.isWhitespace) ?? true
    }

    /// A bare path, or several glued end to end (`/…/a-1.png/…/a-2.png`, two pastes sent with no space between them
    /// by an older build): split after each image extension a `/` follows.
    private static func bareTokens(in line: String, at start: String.Index) -> [Token] {
        guard line[start] == "/" else { return [] }
        var end = line[start...].firstIndex(where: \.isWhitespace) ?? line.endIndex
        while end > line.index(after: start), closers.contains(line[line.index(before: end)]) {
            end = line.index(before: end)
        }
        var tokens: [Token] = []
        var from = start
        let word = NSRange(start..<end, in: line)
        for match in gluedImageEnd?.matches(in: line, range: word) ?? [] {
            guard let cut = Range(match.range, in: line)?.upperBound else { continue }
            tokens.append(Token(range: from..<cut, raw: line[from..<cut], path: String(line[from..<cut])))
            from = cut
        }
        tokens.append(Token(range: from..<end, raw: line[from..<end], path: String(line[from..<end])))
        return tokens
    }

    /// An image extension a `/` follows: where one glued path ends and the next begins.
    private static let gluedImageEnd = try? NSRegularExpression(
        pattern: "\\.(?:" + imageExtensions.sorted().joined(separator: "|") + ")(?=/)", options: .caseInsensitive
    )

    private static func quotedToken(in line: String, at start: String.Index) -> Token? {
        guard line[start] == "\"" else { return nil }
        var index = line.index(after: start)
        guard index < line.endIndex, line[index] == "/" else { return nil }
        var path = ""
        while index < line.endIndex {
            let char = line[index]
            let next = line.index(after: index)
            if char == "\\", next < line.endIndex, line[next] == "\"" || line[next] == "\\" {
                path.append(line[next])
                index = line.index(after: next)
                continue
            }
            if char == "\"" {
                guard endsToken(line, at: next) else { return nil }
                return Token(range: start..<next, raw: line[start..<next], path: path)
            }
            path.append(char)
            index = next
        }
        return nil
    }
}
