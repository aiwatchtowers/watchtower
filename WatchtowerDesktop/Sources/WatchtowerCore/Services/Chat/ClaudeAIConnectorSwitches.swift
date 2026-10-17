import Foundation
import Yams

/// `ai.claude_ai.*` in config.yaml (Go: `config.ClaudeAIConfig`): everything
/// is on by default (ask #236); the owner narrows it in Settings.
package struct ClaudeAIConnectorSwitches: Equatable, Sendable {
    /// `ai.claude_ai.connectors`: false loads no connector at all.
    package var connectors = true
    /// `ai.claude_ai.disabled_connectors`: display names switched off one by one.
    package var disabled: [String] = []

    package init(connectors: Bool = true, disabled: [String] = []) {
        self.connectors = connectors
        self.disabled = disabled
    }

    /// Whether `name` is switched off. Go matches by server token
    /// (`chat.DisabledConnectorTokens`), so "claude.ai Gmail" or "Connector_A"
    /// in the config switch off "Gmail" and "Connector A" — matched the same here.
    package func isDisabled(_ name: String) -> Bool {
        let token = Self.serverToken(name)
        return disabled.contains { Self.serverToken($0) == token }
    }

    /// The list with `name` switched on or off: on drops every spelling of it,
    /// off adds it unless a spelling is already there. Sorted.
    package func disabling(_ name: String, _ off: Bool) -> [String] {
        let token = Self.serverToken(name)
        var names = disabled.filter { Self.serverToken($0) != token || off }
        if off, !isDisabled(name) { names.append(name) }
        return names.sorted()
    }

    /// Go's `connectorpolicy.ServerToken(connectorServerName(name))`: the
    /// "claude.ai " prefix, each rune outside [A-Za-z0-9_-] as "_", runs of
    /// "_" folded, edge "_" trimmed (pinned by `TestServerToken_Mapping`).
    package static func serverToken(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = trimmed.hasPrefix("claude.ai ") ? trimmed : "claude.ai " + trimmed
        var token = String(server.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return Character(scalar)
            default: return "_"
            }
        })
        while token.contains("__") { token = token.replacingOccurrences(of: "__", with: "_") }
        return token.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// The switches in the config file at `path`; the defaults when the file
    /// or the keys are missing. Values are read as Go's weak decoding reads
    /// them; one it can't load throws, naming the key. Go's loader reads `disabled_connectors` as a list or
    /// as one comma-separated string — both are read here too.
    package static func read(configPath path: String) throws -> Self {
        guard let data = FileManager.default.contents(atPath: path) else {
            if FileManager.default.fileExists(atPath: path) { throw failure("config.yaml can't be read") }
            return Self()
        }
        guard let text = String(data: data, encoding: .utf8) else { throw failure("config.yaml is not UTF-8 text") }
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: text)
        } catch {
            throw failure("config.yaml is not valid YAML: \(error)")
        }
        // An empty document is an empty config, as Go reads it.
        guard let loaded, !(loaded is NSNull) else { return Self() }
        guard let yaml = loaded as? [String: Any] else { throw failure("config.yaml is not a YAML mapping") }
        guard let claudeAI = try mapping(yaml["ai"], key: "ai")
            .flatMap({ try mapping($0["claude_ai"], key: "ai.claude_ai") }) else { return Self() }
        var switches = Self()
        if let raw = claudeAI["connectors"], !(raw is NSNull) {
            switches.connectors = try weakBool(raw)
        }
        switch claudeAI["disabled_connectors"] {
        case nil, is NSNull:
            break
        case let csv as String:
            switches.disabled = normalized(csv.components(separatedBy: ","))
        case let list as [Any]:
            switches.disabled = normalized(try list.map { item in
                guard let name = scalarText(item) else {
                    throw failure("ai.claude_ai.disabled_connectors in config.yaml holds a non-name entry")
                }
                return name
            })
        case let scalar?:
            // Go's weak decoding reads a lone scalar as a one-name list.
            guard let name = scalarText(scalar) else {
                throw failure("ai.claude_ai.disabled_connectors in config.yaml is not a list of names")
            }
            switches.disabled = normalized([name])
        }
        return switches
    }

    /// viper decodes weakly (`WeaklyTypedInput`): a number is true unless
    /// 0, a string is read by Go's `strconv.ParseBool`; anything else fails Go's load.
    private static func weakBool(_ value: Any) throws -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let int as Int: return int != 0
        case let double as Double: return double != 0
        case let text as String where ["1", "t", "T", "TRUE", "true", "True"].contains(text): return true
        case let text as String where ["0", "f", "F", "FALSE", "false", "False"].contains(text): return false
        default: throw failure("ai.claude_ai.connectors in config.yaml is not true or false")
        }
    }

    private static func scalarText(_ value: Any) -> String? {
        switch value {
        case is String, is Int, is Double, is Bool: return String(describing: value)
        default: return nil
        }
    }

    /// nil when absent; a present non-mapping throws.
    private static func mapping(_ value: Any?, key: String) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let map = value as? [String: Any] else { throw failure("\(key) in config.yaml is not a mapping") }
        return map
    }

    private static func failure(_ message: String) -> ClaudeAIConnectorsReadError {
        ClaudeAIConnectorsReadError(message: message)
    }

    /// Trimmed, non-empty, first spelling kept — as `config set` stores them.
    private static func normalized(_ names: [String]) -> [String] {
        var out: [String] = []
        for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty && !out.contains(name) {
            out.append(name)
        }
        return out
    }
}
