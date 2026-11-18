import Foundation

/// One `@` mention of a stored owner message's REFERENCED line.
public struct ChatOwnerTextReference: Equatable, Sendable {
    public let token: String
    public let label: String

    public init(token: String, label: String) {
        self.token = token
        self.label = label
    }
}

/// A stored owner message split for display: the picked skill, the owner's own words and the mentions.
public struct ChatOwnerTextParts: Equatable, Sendable {
    public let skill: String?
    public let body: String
    public let referencedLine: String?
    public let references: [ChatOwnerTextReference]
}

/// Reads the stored owner text the engine composes (Go `chatstore.ComposeOwnerText`, pinned by
/// `internal/chatengine/testdata/compose_cases.json`):
///
///     Use skill <name>: load it with load_skill first.   ← optional
///
///     <the owner's text>
///
///     REFERENCED: person:<id> "Label"; jira:PROJ-1 "PROJ-1"   ← optional
///
/// The stored message is exactly what was sent (CHAT-01, replay fidelity); a bubble shows `displayParts`: the
/// owner's text plus chips. A look-alike the composer escaped (a zero-width space before it) reads as text.
public enum ChatOwnerText {
    static let referencedPrefix = "REFERENCED: "
    private static let skillLinePrefix = "Use skill "
    private static let skillLineSuffix = ": load it with load_skill first."
    private static let escapeMarker = "\u{200B}"

    public static func displayParts(_ stored: String) -> ChatOwnerTextParts {
        var rest = stored
        var skill: String?
        let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if let name = skillName(inLine: firstLine) {
            skill = name
            rest = String(rest.dropFirst(firstLine.count)).trimmingPrefixNewlines()
        }

        var referencedLine: String?
        var references: [ChatOwnerTextReference] = []
        if let marker = referencedMarker(in: rest) {
            let line = String(rest[marker.upperBound...].prefix { $0 != "\n" })
            if let parsed = strictReferences(line) {
                referencedLine = referencedPrefix + line
                references = parsed
                rest = String(rest[..<marker.lowerBound])
            }
            // Else: looks like a REFERENCED line but doesn't strictly parse —
            // never `compose`'s own; leave it as ordinary body text untouched.
        }
        let body = rest.replacingOccurrences(of: escapeMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatOwnerTextParts(skill: skill, body: body, referencedLine: referencedLine, references: references)
    }

    private static func skillName(inLine line: String) -> String? {
        guard line.hasPrefix(skillLinePrefix), line.hasSuffix(skillLineSuffix) else { return nil }
        let name = String(line.dropFirst(skillLinePrefix.count).dropLast(skillLineSuffix.count))
        return ChatSkillName.isValid(name) ? name : nil
    }

    private static func referencedMarker(in text: String) -> Range<String.Index>? {
        if let range = text.range(of: "\n\n" + referencedPrefix, options: .backwards) {
            return range
        }
        return text.hasPrefix(referencedPrefix) ? text.range(of: referencedPrefix) : nil
    }

    private static func strictReferences(_ line: String) -> [ChatOwnerTextReference]? {
        let items = splitReferences(line)
        guard !items.isEmpty else { return nil }
        var result: [ChatOwnerTextReference] = []
        for item in items {
            guard let reference = parseReference(item) else { return nil }
            result.append(reference)
        }
        return result
    }

    private static func parseReference(_ item: String) -> ChatOwnerTextReference? {
        guard let space = item.firstIndex(of: " ") else { return nil }
        let token = String(item[..<space])
        let quoted = item[item.index(after: space)...]
        guard !token.isEmpty, quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else {
            return nil
        }
        return ChatOwnerTextReference(token: token, label: unescape(String(quoted.dropFirst().dropLast())))
    }

    private static func splitReferences(_ line: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" && inQuotes { current.append(char); escaped = true; continue }
            if char == "\"" { inQuotes.toggle() }
            if char == ";" && !inQuotes {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(char)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(current.trimmingCharacters(in: .whitespaces))
        }
        return items
    }

    private static func unescape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

private extension String {
    func trimmingPrefixNewlines() -> String {
        String(drop { $0 == "\n" })
    }
}
