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

/// The add sheet's mirror of the CLI's refusal (`netsec.RequireSecureURL` in
/// `watchtower connections add`): headers are a secret, so an http server
/// that gets them must be https unless it is on this Mac (a loopback host).
/// Checked inline so the sheet disables Add instead of only failing in the CLI.
public enum ExternalConnectionTransportRule {
    public static let caption =
        "Headers are a secret: the server URL must use https. Plain http is allowed only for "
            + "localhost, 127.0.0.1 or ::1."

    /// True when `url` is plain http to a host other than loopback — headers
    /// sent there would travel in cleartext.
    public static func sendsSecretInCleartext(url: String) -> Bool {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http" else { return false }
        return !isLoopbackHost(components.host ?? "")
    }

    /// "localhost" or a loopback IP literal (127.0.0.0/8, ::1, ::ffff:127.x),
    /// as Go's `netsec.IsLoopbackHost`.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var trimmed = host
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { trimmed = String(trimmed.dropFirst().dropLast()) }
        if trimmed.lowercased() == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, trimmed, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        // IPv4-mapped (::ffff:a.b.c.d): loopback when the IPv4 part is.
        return bytes[0 ..< 10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
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
