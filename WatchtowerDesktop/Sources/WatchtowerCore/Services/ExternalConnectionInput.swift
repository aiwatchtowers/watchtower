import Foundation

/// Errors from the add-sheet input helpers, surfaced to the owner instead of
/// being folded into an "absent" result.
public enum ExternalConnectionInputError: Error, Equatable {
    /// The secret map could not be encoded as JSON. Not expected for a map of
    /// strings; kept distinct from "no secret" so an encoder problem can never
    /// masquerade as the owner having entered nothing.
    case secretEncodingFailed
    /// The arguments field opens a quote it never closes. A shell would refuse
    /// the line; we tell the owner instead of passing an empty argument.
    case unclosedQuote
}

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
    /// Duplicate keys: the last row wins. Throws only when encoding fails —
    /// deliberately distinct from the nil "no secret" result.
    public static func json(kind: String, pairs: [(key: String, value: String)]) throws -> String? {
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
        let data = try encoder.encode([field: map])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExternalConnectionInputError.secretEncodingFailed
        }
        return text
    }
}

/// Shell-like tokenizer for the add-sheet's arguments field: whitespace splits
/// tokens unless inside single or double quotes, so a quoted path containing a
/// space stays one argument. Explicit empty quotes (`""`) yield one empty
/// argument, as in a shell. Any Unicode whitespace separates tokens — a
/// non-breaking space included, unlike in a shell, since a pasted NBSP in a
/// text field is almost always accidental. Quoting only — no backslash
/// escapes (YAGNI).
/// Throws `unclosedQuote` when a quote is opened and never closed.
public enum CommandArgsTokenizer {
    public static func tokenize(_ text: String) throws -> [String] {
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
        if quote != nil {
            throw ExternalConnectionInputError.unclosedQuote
        }
        if inToken {
            tokens.append(current)
        }
        return tokens
    }
}
