import Foundation

// Port of relay@3a99bd7 `sim/transport.go`: envelopes and record names. The sim is the reference
// model of the relay client rules (`sim/README.md`); like Go's, this port is test-only, has no
// cryptography ("sealing" is plain JSON, the epoch stands for the keys) and skips the README's
// bounded-state notes.

/// A transport (Go `Kind`).
enum SimKind: String, Sendable, CaseIterable {
    case relay
    case cloudkit
}

/// Go's package-level names and timing rules.
enum Sim {
    /// The record in the hub's relay data zone that names its current transport and epoch.
    static let markerName = "transport"
    /// A phone whose transport has been unreachable this long also polls its other mailbox.
    static let pollOtherAfter: TimeInterval = 60
    /// The hub accepts a switch to the relay no sooner than this after the previous one.
    static let relayHoldoff: TimeInterval = 5 * 60
    /// The longest the hub keeps the receiving keys of a previous epoch (the mailbox TTL).
    static let oldEpochKeep: TimeInterval = 14 * 24 * 3_600

    /// The record name of action `seq` in a mailbox; its echo overwrites the same record.
    static func actionName(_ seq: UInt64) -> String {
        "a-\(seq)"
    }

    /// The record name of a control record.
    static func controlName(_ id: String) -> String {
        "c-" + id
    }
}

/// The content of a mailbox record (Go `Envelope`), serialized exactly as Go's `json.Marshal`
/// with the struct's tags: field order, `omitempty` on everything but `kind` and `sender`, Go's
/// string escaping.
struct SimEnvelope: Equatable, Sendable {
    static let kindAction = "action"
    static let kindEcho = "echo"
    static let kindResendFrom = "resend_from"
    static let kindSkipTo = "skip_to"
    static let kindSwitch = "transport_switch"
    static let kindSwitched = "transport_switched"
    static let kindSwitchRejected = "transport_switch_rejected"
    static let kindHubOnRelay = "hub_on_relay"
    static let kindEpochAck = "epoch_ack"

    /// Reasons of a transport_switch.
    static let reasonUser = "user"
    static let reasonEntitlementExpired = "entitlement_expired"
    /// Echo statuses.
    static let statusApplied = "applied"
    static let statusDupe = "duplicate"

    var kind: String
    var sender = ""
    var epoch: UInt64 = 0
    /// The action's number (action, echo); the first number to resend (resend_from); the number
    /// to continue from (skip_to).
    var seq: UInt64 = 0
    var payload = ""
    /// Identifies a control record across its copies on both transports.
    var id = ""
    var target: SimKind?
    var reason = ""
    /// echo: applied or duplicate.
    var status = ""
    /// transport_switch_rejected.
    var retryAfterMs: Int64 = 0
    /// Who switched the hub and when (transport_switched).
    var by = ""
    var atMs: Int64 = 0

    /// "Seals" the envelope (Go `Marshal`).
    func marshal() -> Data {
        var fields = ["\"kind\":" + Self.quote(kind), "\"sender\":" + Self.quote(sender)]
        func add(_ key: String, _ value: String, when present: Bool) {
            if present { fields.append("\"\(key)\":" + value) }
        }
        add("epoch", String(epoch), when: epoch != 0)
        add("seq", String(seq), when: seq != 0)
        add("payload", Self.quote(payload), when: !payload.isEmpty)
        add("id", Self.quote(id), when: !id.isEmpty)
        add("target", Self.quote(target?.rawValue ?? ""), when: target != nil)
        add("reason", Self.quote(reason), when: !reason.isEmpty)
        add("status", Self.quote(status), when: !status.isEmpty)
        add("retry_after_ms", String(retryAfterMs), when: retryAfterMs != 0)
        add("by", Self.quote(by), when: !by.isEmpty)
        add("at_ms", String(atMs), when: atMs != 0)
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    /// "Opens" an envelope (Go `Open`): absent fields are their zero values.
    static func open(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wire = try decoder.decode(Wire.self, from: data)
        return Self(
            kind: wire.kind ?? "", sender: wire.sender ?? "", epoch: wire.epoch ?? 0, seq: wire.seq ?? 0,
            payload: wire.payload ?? "", id: wire.id ?? "", target: wire.target.flatMap(SimKind.init(rawValue:)),
            reason: wire.reason ?? "", status: wire.status ?? "", retryAfterMs: wire.retryAfterMs ?? 0,
            by: wire.by ?? "", atMs: wire.atMs ?? 0)
    }

    /// The kind of a sealed envelope, or "?" when it does not open (Go `KindOf`).
    static func kindOf(_ data: Data) -> String {
        (try? open(data))?.kind ?? "?"
    }

    private struct Wire: Decodable {
        let kind: String?
        let sender: String?
        let epoch: UInt64?
        let seq: UInt64?
        let payload: String?
        let id: String?
        let target: String?
        let reason: String?
        let status: String?
        let retryAfterMs: Int64?
        let by: String?
        let atMs: Int64?
    }

    /// A JSON string as Go's `encoding/json` writes it (HTML-safe escaping, `/` kept).
    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", ">", "&", "\u{2028}", "\u{2029}", "\u{00}"..."\u{1F}":
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
