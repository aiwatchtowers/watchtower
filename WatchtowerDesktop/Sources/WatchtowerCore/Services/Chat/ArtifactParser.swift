import Foundation

package struct ArtifactDraft: Equatable, Sendable {
    package var key: String
    package var kind: String
    package var title: String
    package var meta: [String: String]
    package var content: String
    package var isComplete: Bool

    package init(key: String, kind: String, title: String, meta: [String: String], content: String, isComplete: Bool) {
        self.key = key
        self.kind = kind
        self.title = title
        self.meta = meta
        self.content = content
        self.isComplete = isComplete
    }
}

package struct ParsedMessage: Equatable, Sendable {
    package enum Segment: Equatable, Sendable {
        case markdown(String)
        case artifact(ArtifactDraft)
    }

    package var segments: [Segment]

    package var artifacts: [ArtifactDraft] {
        segments.compactMap { segment -> ArtifactDraft? in
            guard case .artifact(let draft) = segment else { return nil }
            return draft
        }
    }
}

/// Parses `:::artifact key="…" kind="…" title="…" [attrs]` … `:::` blocks out of
/// assistant text (the grammar taught by Go `chat.ArtifactsContract()`; shared
/// fixture `internal/chat/artifacts_examples.md`). Pure and streaming-aware:
/// `final: false` holds back a half-written opener line and reports an open
/// block as an incomplete draft; `final: true` keeps an unterminated block as
/// complete content. A fence inside a ``` / ~~~ code block is literal text.
package enum ArtifactParser {
    package static let knownKinds: Set<String> = ["document", "table", "email", "slack", "event", "code"]
    static let opener = ":::artifact"

    package static func parse(_ text: String, final: Bool) -> ParsedMessage {
        var machine = Machine(final: final)
        let lines = splitLines(text)
        for (index, entry) in lines.enumerated() {
            let trailingPartial = index == lines.count - 1 && !entry.terminated
            guard machine.consume(entry.line, isTrailingPartial: trailingPartial) else { break }
        }
        return machine.finish()
    }

    package static func slug(_ title: String) -> String {
        var out = ""
        var pendingDash = false
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
                if out.count >= 64 { break }
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "artifact" : out
    }

    static func splitLines(_ text: String) -> [(line: Substring, terminated: Bool)] {
        guard !text.isEmpty else { return [] }
        // "\r\n" is ONE Character in Swift, so both separators are listed.
        var parts = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        let endsWithNewline = text.last == "\n" || text.last == "\r\n"
        if endsWithNewline { parts.removeLast() }
        return parts.enumerated().map { index, part in
            (part, endsWithNewline || index < parts.count - 1)
        }
    }

    static func isOpenerLine(_ trimmed: Substring) -> Bool {
        guard trimmed.hasPrefix(opener) else { return false }
        return trimmed.dropFirst(opener.count).first.map(\.isWhitespace) ?? true
    }

    static func isOpenerPrefix(_ trimmed: Substring) -> Bool {
        !trimmed.isEmpty && opener.hasPrefix(trimmed)
    }

    static func parseOpener(_ trimmed: Substring) -> ArtifactDraft? {
        guard var attributes = parseAttributes(trimmed.dropFirst(opener.count)) else { return nil }
        let rawKind = attributes.removeValue(forKey: "kind")?.lowercased() ?? ""
        let rawKey = attributes.removeValue(forKey: "key")?.trimmingCharacters(in: .whitespaces) ?? ""
        let rawTitle = attributes.removeValue(forKey: "title")?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = rawKey.isEmpty ? slug(rawTitle) : rawKey
        let title = rawTitle.isEmpty ? (rawKey.isEmpty ? "Untitled" : rawKey) : rawTitle
        return ArtifactDraft(key: key, kind: knownKinds.contains(rawKind) ? rawKind : "document",
                             title: title, meta: attributes, content: "", isComplete: false)
    }

    /// `name="value"` pairs; `\"` and `\\` are escapes. Nil on any syntax error
    /// (including an unterminated quote).
    static func parseAttributes(_ source: Substring) -> [String: String]? {
        var result: [String: String] = [:]
        var index = source.startIndex
        func advance() { index = source.index(after: index) }
        while true {
            while index < source.endIndex, source[index].isWhitespace { advance() }
            if index == source.endIndex { return result }
            let nameStart = index
            while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" || source[index] == "-" {
                advance()
            }
            let name = source[nameStart..<index].lowercased()
            guard !name.isEmpty, index < source.endIndex, source[index] == "=" else { return nil }
            advance()
            guard index < source.endIndex, source[index] == "\"" else { return nil }
            advance()
            guard let (value, next) = scanQuotedValue(source, from: index) else { return nil }
            result[name] = value
            index = next
        }
    }

    /// Scans the body of a `"…"` value starting right after the opening quote
    /// (`\"` and `\\` are escapes). Nil when the quote never closes.
    private static func scanQuotedValue(_ source: Substring, from start: Substring.Index) -> (String, Substring.Index)? {
        var index = start
        var value = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "\"" || source[next] == "\\" {
                    value.append(source[next])
                    index = source.index(after: next)
                    continue
                }
            } else if character == "\"" {
                return (value, source.index(after: index))
            }
            value.append(character)
            index = source.index(after: index)
        }
        return nil
    }
}

private struct CodeFence {
    let marker: Character
    let length: Int

    static func opening(_ line: Substring) -> Self? {
        let stripped = line.drop { $0 == " " }
        guard line.count - stripped.count <= 3, let marker = stripped.first, marker == "`" || marker == "~" else { return nil }
        let run = stripped.prefix { $0 == marker }.count
        guard run >= 3 else { return nil }
        if marker == "`", stripped.dropFirst(run).contains("`") { return nil }
        return Self(marker: marker, length: run)
    }

    func isClosed(by line: Substring) -> Bool {
        let stripped = line.drop { $0 == " " }
        guard line.count - stripped.count <= 3 else { return false }
        let run = stripped.prefix { $0 == marker }.count
        return run >= length && stripped.dropFirst(run).allSatisfy(\.isWhitespace)
    }
}

private struct Machine {
    let final: Bool
    var segments: [ParsedMessage.Segment] = []
    var markdown: [Substring] = []
    var outerFence: CodeFence?
    var open: ArtifactDraft?
    var innerFence: CodeFence?
    var body: [Substring] = []

    init(final: Bool) { self.final = final }

    /// False = stop: the rest of a still-streaming text is held back.
    mutating func consume(_ line: Substring, isTrailingPartial: Bool) -> Bool {
        if open != nil {
            consumeArtifactLine(line)
            return true
        }
        if let fence = outerFence {
            if fence.isClosed(by: line) { outerFence = nil }
            markdown.append(line)
            return true
        }
        if let fence = CodeFence.opening(line) {
            outerFence = fence
            markdown.append(line)
            return true
        }
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let candidate = ArtifactParser.isOpenerLine(trimmed)
        if isTrailingPartial, !final, candidate || ArtifactParser.isOpenerPrefix(trimmed) {
            return false
        }
        if candidate, let draft = ArtifactParser.parseOpener(trimmed) {
            flushMarkdown()
            open = draft
            innerFence = nil
            body = []
            return true
        }
        markdown.append(line)
        return true
    }

    private mutating func consumeArtifactLine(_ line: Substring) {
        guard var draft = open else { return }
        if innerFence == nil, line.trimmingCharacters(in: .whitespaces) == ":::" {
            draft.content = body.joined(separator: "\n")
            draft.isComplete = true
            segments.append(.artifact(draft))
            open = nil
            body = []
            return
        }
        if draft.kind != "code" {
            if let fence = innerFence {
                if fence.isClosed(by: line) { innerFence = nil }
            } else if let fence = CodeFence.opening(line) {
                innerFence = fence
            }
        }
        body.append(line)
    }

    private mutating func flushMarkdown() {
        let joined = markdown.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.markdown(joined))
        }
        markdown = []
    }

    mutating func finish() -> ParsedMessage {
        if var draft = open {
            draft.content = body.joined(separator: "\n")
            draft.isComplete = final
            segments.append(.artifact(draft))
            open = nil
        }
        flushMarkdown()
        return ParsedMessage(segments: segments)
    }
}
