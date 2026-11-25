import Foundation

/// The images in an owner's Workchat line, read off its text for display only: a pasted image goes to the agent as
/// its saved file's path (`WorkchatOutgoing.quoted`, in place of its `[Image #N]` token), a dropped image file as its
/// path on a line of its own. The bubble shows each as a thumbnail and the text without those paths; what was sent,
/// the feed's entry and the echo match are untouched.
///
/// A path counts when it is absolute, ends in an image extension and stands as a whole token (bare, or in double
/// quotes with `\"` and `\\` escaped), and either sits in a `workchat-attachments` folder (Watchtower's own pastes,
/// inline or on their own line; a swept one is still an image, shown missing) or is a file that exists and stands on
/// a line of its own (a dropped or picked image). Any other image path — one named mid-sentence, one not on disk — is
/// the owner's prose and stays text.
package struct WorkchatOwnerImages: Equatable, Sendable {
    package struct ImageFile: Equatable, Hashable, Sendable {
        package let path: String
        /// The file is on disk now; a missing one shows as a chip with its name.
        package let exists: Bool

        package init(path: String, exists: Bool) {
            self.path = path
            self.exists = exists
        }

        package var name: String { (path as NSString).lastPathComponent }
    }

    /// The text to show: the image paths taken out, a line left empty by them dropped, and Go's `[image]` marker
    /// line dropped when a thumbnail stands for it. Unchanged when no image was found.
    package let text: String
    /// The images in order of first appearance, each path once.
    package let images: [ImageFile]

    package static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic"]
    private static let pastesFolder = "/workchat-attachments/"
    private static let imageMarker = "[image]"

    package static func split(
        _ text: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Self {
        guard text.contains("/") else { return Self(text: text, images: []) }
        var images: [ImageFile] = []
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let tokens = pathTokens(in: line)
            let alone = tokens.count == 1 && tokens[0].raw == line.trimmingCharacters(in: .whitespaces)
            let found = tokens.compactMap { token in
                image(token.path, alone: alone, fileExists: fileExists).map { (token, $0) }
            }
            guard !found.isEmpty else {
                lines.append(line)
                continue
            }
            for (_, image) in found where !images.contains(where: { $0.path == image.path }) { images.append(image) }
            var kept = line
            for (token, _) in found.reversed() { kept.replaceSubrange(token.range, with: " ") }
            let tidy = kept.split { $0 == " " || $0 == "\t" }.joined(separator: " ")
            if !tidy.isEmpty { lines.append(tidy) }
        }
        guard !images.isEmpty else { return Self(text: text, images: []) }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == imageMarker }
        let shown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(text: shown, images: images)
    }

    private static func image(_ path: String, alone: Bool, fileExists: (String) -> Bool) -> ImageFile? {
        guard path.hasPrefix("/"),
              imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        if path.contains(pastesFolder) { return ImageFile(path: path, exists: fileExists(path)) }
        return alone && fileExists(path) ? ImageFile(path: path, exists: true) : nil
    }

    private struct Token {
        let range: Range<String.Index>
        let raw: Substring
        let path: String
    }

    /// The whole-token absolute paths of one line: bare (`/…` up to whitespace) or double-quoted with `\"` and `\\`
    /// escaped (`"/…"` followed by whitespace or the end), each starting the line or after whitespace.
    private static func pathTokens(in line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            let atBoundary = index == line.startIndex || line[line.index(before: index)].isWhitespace
            guard atBoundary else {
                index = line.index(after: index)
                continue
            }
            if let token = quotedToken(in: line, at: index) ?? bareToken(in: line, at: index) {
                tokens.append(token)
                index = token.range.upperBound
            } else {
                index = line.index(after: index)
            }
        }
        return tokens
    }

    private static func bareToken(in line: String, at start: String.Index) -> Token? {
        guard line[start] == "/" else { return nil }
        let end = line[start...].firstIndex(where: \.isWhitespace) ?? line.endIndex
        return Token(range: start..<end, raw: line[start..<end], path: String(line[start..<end]))
    }

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
                guard next == line.endIndex || line[next].isWhitespace else { return nil }
                return Token(range: start..<next, raw: line[start..<next], path: path)
            }
            path.append(char)
            index = next
        }
        return nil
    }
}
