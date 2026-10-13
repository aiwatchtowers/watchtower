import Foundation

/// The text rule of a `session_input` line (spec §6.6, PROJ-16), shared by
/// the phone and the Mac so both count the same: a CRLF and every other line
/// break or control character become one space each, format characters
/// (the zero-width joiner of an emoji sequence) stay, and the ends are
/// trimmed. A line is 1–`maxLength` characters (grapheme clusters) after
/// that.
public enum SessionInputText {
    public static let maxLength = 4000

    public static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            defer { previousCR = scalar == "\r" }
            if scalar == "\n", previousCR { continue }
            out.append(isBreak(scalar) ? " " : scalar)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` normalizes to a line the Mac takes.
    public static func isSendable(_ text: String) -> Bool {
        let line = normalize(text)
        return !line.isEmpty && line.count <= maxLength
    }

    private static func isBreak(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .format { return false }
        return CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
    }
}
