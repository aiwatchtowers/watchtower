import CryptoKit
import Foundation

extension ArtifactAction {
    /// Go `blocks.ActionHash`: the first 16 hex characters of the SHA-256 of
    /// the action's canonical JSON (Go `db.InboxAction` as `blocks.marshal`
    /// writes it). The button's identity in a target proposal's context;
    /// the shared fixture `internal/automations/blocks/testdata/blocks_cases.json`
    /// pins it per action.
    public var hash: String {
        let digest = SHA256.hash(data: Data(GoJSON.canonical(self).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Go's `encoding/json` byte for byte, for the two forms a block document
/// holds: the canonical form (`blocks.marshal`, no HTML escaping) and a
/// reply's `data` (`json.Marshal`: HTML-escaped, keys sorted). Both escape
/// `"` and `\`, write `\b \f \n \r \t` as such, other control characters as
/// `\u00XX`, U+2028/U+2029 as `\u2028`/`\u2029`, and leave `/` alone.
enum GoJSON {
    /// The action's canonical JSON: Go `db.InboxAction`'s fields in their
    /// struct order, empty ones omitted (`omitempty`), `data` copied as stored.
    static func canonical(_ action: ArtifactAction) -> String {
        var fields = [("label", string(action.label)), ("kind", string(storedKind(action.kind)))]
        var data: String?
        switch action.payload {
        case let .open(url):
            fields.append(("open", string(url)))
        case let .chat(text):
            fields.append(("chat", string(text)))
        case let .agent(task, workbench):
            var agent = [("task", string(task))]
            switch workbench {
            case let .id(id): agent.append(("workbench", String(id)))
            // The workbench is `json.Marshal`'s bytes: HTML-escaped.
            case let .name(name): agent.append(("workbench", string(name, escapeHTML: true)))
            case nil: break
            }
            fields.append(("agent", object(agent)))
        case let .reply(value, dataJSON):
            if !value.isEmpty { fields.append(("reply", string(value))) }
            data = dataJSON
        case let .target(target):
            var task = [("title", string(target.title))]
            if let intent = target.intent { task.append(("intent", string(intent))) }
            if let parent = target.parent, parent != 0 { task.append(("parent", String(parent))) }
            fields.append(("target", object(task)))
        }
        if let data { fields.append(("data", data)) }
        if action.primary { fields.append(("primary", "true")) }
        return object(fields)
    }

    /// Go `json.Marshal` of a value `JSONSerialization` read: objects with
    /// keys in byte order, strings HTML-escaped, numbers as Go writes a
    /// float64 or an int64.
    static func marshal(_ value: Any) throws -> String {
        switch value {
        case is NSNull:
            return "null"
        case let text as String:
            return string(text, escapeHTML: true)
        case let number as NSNumber:
            return try self.number(number)
        case let items as [Any]:
            return "[" + (try items.map(marshal)).joined(separator: ",") + "]"
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return object(try keys.map { ($0, try marshal(dictionary[$0] as Any)) }, escapeHTML: true)
        default:
            throw ArtifactJSON.Unreadable()
        }
    }

    private static func storedKind(_ kind: ArtifactActionKind) -> String {
        kind == .open ? "link" : kind.rawValue
    }

    private static func object(_ fields: [(String, String)], escapeHTML: Bool = false) -> String {
        "{" + fields.map { string($0.0, escapeHTML: escapeHTML) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    static func string(_ text: String, escapeHTML: Bool = false) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", ">", "&":
                if escapeHTML { out += unicodeEscape(scalar) } else { out.unicodeScalars.append(scalar) }
            case "\u{2028}", "\u{2029}":
                out += unicodeEscape(scalar)
            case _ where scalar.value < 0x20:
                out += unicodeEscape(scalar)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func unicodeEscape(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
    }

    private static func number(_ number: NSNumber) throws -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        // JSONSerialization reads an integer past Int64 (Go writes a float64
        // up to 1e21 in plain decimal) as an NSDecimalNumber, whose
        // `doubleValue` is not correctly rounded: parse its digits instead
        // (Go writes at most 17 significant ones, within its 38).
        let decimal = number as? NSDecimalNumber
        if !CFNumberIsFloatType(number), decimal == nil { return number.stringValue }
        guard let value = decimal.map({ Double($0.stringValue) }) ?? number.doubleValue,
              value.isFinite else { throw ArtifactJSON.Unreadable() }
        return float(value)
    }

    /// Go's float64 encoding: the shortest digits that read back, plain
    /// decimal for 1e-6 ≤ |x| < 1e21, else `d.ddde±XX` (a negative
    /// exponent without its leading zero, a positive one of two digits at least).
    static func float(_ value: Double) -> String {
        let sign = value.sign == .minus ? "-" : ""
        // Swift's description is also the shortest round-trip form; only
        // its layout differs from Go's, so take its digits and exponent.
        let text = value.magnitude.description
        let parts = text.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1)
        var digits = String(mantissa[0]) + (mantissa.count == 2 ? String(mantissa[1]) : "")
        var point = mantissa[0].count + exponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        if digits == "0" { return sign + "0" }

        let magnitude = value.magnitude
        if magnitude < 1e-6 || magnitude >= 1e21 {
            let power = point - 1
            let fraction = digits.dropFirst()
            let exponentText = power < 0 ? "-\(-power)" : "+" + (power < 10 ? "0\(power)" : "\(power)")
            return sign + String(digits.prefix(1)) + (fraction.isEmpty ? "" : "." + String(fraction)) + "e" + exponentText
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: point)
        return sign + String(digits[..<split]) + "." + String(digits[split...])
    }
}
