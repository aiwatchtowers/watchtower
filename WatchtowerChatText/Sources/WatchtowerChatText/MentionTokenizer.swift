import Foundation

/// A trigger character's position (UTF-16 offset, the `NSTextView`
/// `selectedRange` unit) and the query typed after it, up to the cursor.
public struct ComposerTrigger: Equatable, Sendable {
    public let start: Int
    public let query: String

    public init(start: Int, query: String) {
        self.start = start
        self.query = query
    }
}

/// A text edit the composer applies: the new text and the caret after it.
public struct ComposerEdit: Equatable, Sendable {
    public let text: String
    public let cursor: Int

    public init(text: String, cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

public enum MentionTokenizer {
    public static let maxQueryLength = 40

    /// The query after an active `@` ending at `cursor`, or nil.
    public static func activeQuery(text: String, cursor: Int) -> String? {
        activeMention(text: text, cursor: cursor)?.query
    }

    /// An `@` opens a mention only at the start of the text or after
    /// whitespace (so `anna@example.com` never does), and the query runs to
    /// the cursor without whitespace.
    public static func activeMention(text: String, cursor: Int) -> ComposerTrigger? {
        trigger(text: text, cursor: cursor, character: "@")
    }

    /// A `/` opens the skill picker only as the first non-whitespace character
    /// of the draft, with a query that is a valid skill-name prefix.
    public static func activeSkill(text: String, cursor: Int) -> ComposerTrigger? {
        guard let trigger = trigger(text: text, cursor: cursor, character: "/") else { return nil }
        let before = String(decoding: Array(text.utf16)[..<trigger.start], as: UTF16.self)
        guard before.allSatisfy(\.isWhitespace) else { return nil }
        guard trigger.query.isEmpty || ChatSkillName.isValid(trigger.query) else { return nil }
        return trigger
    }

    /// Replaces `trigger.start ..< cursor` with `replacement`.
    public static func replace(
        _ trigger: ComposerTrigger, in text: String, cursor: Int, with replacement: String
    ) -> ComposerEdit {
        let units = Array(text.utf16)
        let start = max(0, min(trigger.start, units.count))
        let end = max(start, min(cursor, units.count))
        let prefix = String(decoding: units[..<start], as: UTF16.self)
        let suffix = String(decoding: units[end...], as: UTF16.self)
        return ComposerEdit(text: prefix + replacement + suffix, cursor: start + replacement.utf16.count)
    }

    /// Scans back from `cursor` to `character`; nil on whitespace first, on a
    /// non-boundary before the trigger, or on an over-long query.
    public static func trigger(text: String, cursor: Int, character: Character) -> ComposerTrigger? {
        let units = Array(text.utf16)
        guard cursor >= 0, cursor <= units.count, let mark = character.utf16.first else { return nil }
        var index = cursor - 1
        while index >= 0 {
            let unit = units[index]
            if unit == mark {
                guard index == 0 || isWhitespace(units[index - 1]) else { return nil }
                let query = String(decoding: units[(index + 1)..<cursor], as: UTF16.self)
                guard query.count <= maxQueryLength else { return nil }
                return ComposerTrigger(start: index, query: query)
            }
            if isWhitespace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

/// A skill's filename-stem identity: lowercase alphanumerics and hyphens, not
/// starting with a hyphen. It doubles as the path-traversal guard on the Go
/// side, so it must never admit a separator, a dot, or an empty string.
public enum ChatSkillName {
    public static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let lowerDigit = (first >= "a" && first <= "z") || (first >= "0" && first <= "9")
        guard lowerDigit else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
        }
    }
}
