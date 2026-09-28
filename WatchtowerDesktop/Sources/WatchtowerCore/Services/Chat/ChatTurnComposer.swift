import Foundation

package struct ChatTurnReference: Equatable, Sendable {
    package let token: String
    package let label: String

    package init(token: String, label: String) {
        self.token = token
        self.label = label
    }
}

package struct ChatTurnDisplayParts: Equatable, Sendable {
    package let skill: String?
    package let body: String
    package let referencedLine: String?
    package let references: [ChatTurnReference]
}

/// The stored/sent user-turn format (spec §4.3, §6.2, §6.3), one place:
///
///     Use skill <name>: load it with load_skill first.   ← optional
///
///     <the owner's text>
///
///     REFERENCED: person:<id> "Label"; jira:PROJ-1 "PROJ-1"   ← optional
///
/// The stored message is exactly what was sent (CHAT-01, and replay
/// fidelity); the bubble renders `displayParts` so the owner sees their text
/// plus chips.
package enum ChatTurnComposer {
    static let referencedPrefix = "REFERENCED: "
    private static let skillLinePrefix = "Use skill "
    private static let skillLineSuffix = ": load it with load_skill first."
    /// A zero-width space (never produced by normal typing, and not part of
    /// Unicode's White_Space property, so `trimmingCharacters` never touches
    /// it) — `compose` inserts it right where a real sentinel would start
    /// whenever the OWNER's own text organically collides with the skill
    /// line or a REFERENCED block but no real skill/mentions are attached.
    /// Its mere presence breaks the exact-prefix match `skillName`/
    /// `referencedMarker` require, so `displayParts` naturally reads the
    /// collision as ordinary text; a final blanket strip removes it so the
    /// round trip reproduces the owner's text exactly (review Important
    /// finding 1 / controller ruling).
    private static let escapeMarker = "\u{200B}"

    package static func skillLine(_ name: String) -> String {
        skillLinePrefix + name + skillLineSuffix
    }

    /// The skill name when `line` is exactly a `skillLine`, else nil.
    private static func skillName(inLine line: String) -> String? {
        guard line.hasPrefix(skillLinePrefix), line.hasSuffix(skillLineSuffix) else { return nil }
        let name = String(line.dropFirst(skillLinePrefix.count).dropLast(skillLineSuffix.count))
        return SkillsCatalog.isValidSkillName(name) ? name : nil
    }

    package static func compose(text: String, skill: String?, mentions: [MentionCandidate]) -> String {
        var parts: [String] = []
        if let skill { parts.append(skillLine(skill)) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = escapedBody(trimmed, hasSkill: skill != nil, hasReferences: !mentions.isEmpty)
        if !body.isEmpty { parts.append(body) }
        if !mentions.isEmpty {
            let refs = mentions.map { "\($0.referenceToken) \"\(escape($0.label))\"" }
            parts.append(referencedPrefix + refs.joined(separator: "; "))
        }
        return parts.joined(separator: "\n\n")
    }

    package static func displayParts(_ stored: String) -> ChatTurnDisplayParts {
        var rest = stored
        var skill: String?
        let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if let name = skillName(inLine: firstLine) {
            skill = name
            rest = String(rest.dropFirst(firstLine.count)).trimmingPrefixNewlines()
        }

        var referencedLine: String?
        var references: [ChatTurnReference] = []
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
        return ChatTurnDisplayParts(skill: skill, body: body, referencedLine: referencedLine, references: references)
    }

    /// The stored turn for an edited message: same skill and references, new body.
    package static func recompose(stored: String, newBody: String) -> String {
        let parts = displayParts(stored)
        var out: [String] = []
        if let skill = parts.skill { out.append(skillLine(skill)) }
        let trimmed = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = escapedBody(trimmed, hasSkill: parts.skill != nil, hasReferences: parts.referencedLine != nil)
        if !body.isEmpty { out.append(body) }
        if let line = parts.referencedLine { out.append(line) }
        return out.joined(separator: "\n\n")
    }

    /// Escapes a leading skill-sentence look-alike (when `hasSkill` is
    /// false) or EVERY REFERENCED-block look-alike (when `hasReferences` is
    /// false) in the owner's own already-trimmed text, so `displayParts` can
    /// never mistake organically-typed text for a marker `compose` didn't
    /// actually add — escaping only the last one would let `displayParts`
    /// fall back to an earlier one and truncate the body there. A no-op for
    /// text that doesn't collide.
    private static func escapedBody(_ text: String, hasSkill: Bool, hasReferences: Bool) -> String {
        var body = text
        if !hasSkill {
            let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            if skillName(inLine: firstLine) != nil {
                body = escapeMarker + body
            }
        }
        if !hasReferences {
            // Last to first, so each insertion leaves the earlier indices valid.
            for wordStart in referencedLookAlikeStarts(in: body).reversed() {
                body.insert(contentsOf: escapeMarker, at: wordStart)
            }
        }
        return body
    }

    /// Where each `REFERENCED: ` that starts the text or follows a blank line
    /// begins, when its line parses strictly — every spot `displayParts`
    /// could read as a real marker.
    private static func referencedLookAlikeStarts(in text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var searchFrom = text.startIndex
        while let range = text.range(of: referencedPrefix, range: searchFrom..<text.endIndex) {
            searchFrom = range.upperBound
            let atStart = range.lowerBound == text.startIndex
            guard atStart || text[..<range.lowerBound].hasSuffix("\n\n") else { continue }
            let line = String(text[range.upperBound...].prefix { $0 != "\n" })
            if strictReferences(line) != nil { starts.append(range.lowerBound) }
        }
        return starts
    }

    /// The LAST `REFERENCED: ` that starts the text or follows a blank line.
    private static func referencedMarker(in text: String) -> Range<String.Index>? {
        if let range = text.range(of: "\n\n" + referencedPrefix, options: .backwards) {
            return range
        }
        return text.hasPrefix(referencedPrefix) ? text.range(of: referencedPrefix) : nil
    }

    /// Succeeds only when the line is non-empty AND every `;`-separated item
    /// parses as a well-formed `<token> "<escaped label>"` — a single
    /// malformed (or absent) item fails the WHOLE line rather than silently
    /// dropping just that item, so the owner's own text that merely starts
    /// with "REFERENCED: " (without ever producing a fully well-formed line)
    /// is never misread as a real marker and never has its body truncated
    /// (review Important finding 1 / controller ruling).
    private static func strictReferences(_ line: String) -> [ChatTurnReference]? {
        let items = splitReferences(line)
        guard !items.isEmpty else { return nil }
        var result: [ChatTurnReference] = []
        for item in items {
            guard let reference = parseReference(item) else { return nil }
            result.append(reference)
        }
        return result
    }

    /// One `<token> "<escaped label>"` item; nil on any malformed shape.
    private static func parseReference(_ item: String) -> ChatTurnReference? {
        guard let space = item.firstIndex(of: " ") else { return nil }
        let token = String(item[..<space])
        let quoted = item[item.index(after: space)...]
        guard !token.isEmpty, quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else {
            return nil
        }
        return ChatTurnReference(token: token, label: unescape(String(quoted.dropFirst().dropLast())))
    }

    /// Splits on `; ` outside quoted labels.
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

    private static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
