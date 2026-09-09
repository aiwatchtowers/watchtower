import Foundation

/// Builds the secret JSON a Quick Connection pipes to
/// `watchtower connections add --secret-stdin`. Field names match Go's
/// `externalmcp.Secret` verbatim (`env` for a stdio server, `headers` for an
/// http one). The transport is untouched: the JSON still travels via stdin,
/// never argv (QC-03) — this only replaces hand-typed JSON with a structured
/// key/value editor.
public enum ExternalConnectionSecretBuilder {
    /// Returns the JSON string, or nil when no row with a non-empty key
    /// survives (⇒ the caller sends no secret at all). Keys are trimmed;
    /// values are passed through untouched so a secret is never mangled.
    public static func json(kind: String, pairs: [(key: String, value: String)]) -> String? {
        var map: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            map[key] = pair.value
        }
        guard !map.isEmpty else { return nil }
        let field = kind == "http" ? "headers" : "env"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode([field: map]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

/// Shell-like tokenizer for the add-sheet's arguments field: whitespace splits
/// tokens unless inside single or double quotes, so a quoted path containing a
/// space stays one argument. Quoting only — no backslash escapes (YAGNI).
public enum CommandArgsTokenizer {
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var inToken = false
        for ch in text {
            if let open = quote {
                if ch == open {
                    quote = nil
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inToken = true
            } else if ch.isWhitespace {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
            } else {
                current.append(ch)
                inToken = true
            }
        }
        if inToken {
            tokens.append(current)
        }
        return tokens
    }
}
