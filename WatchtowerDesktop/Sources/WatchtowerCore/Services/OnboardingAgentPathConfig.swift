import Foundation

/// The onboarding agent check's `config.yaml` edit: pins `claude_path` /
/// `codex_path` (`AgentSetup.pathKey`) to a binary the owner picked by hand.
package enum OnboardingAgentPathConfig {
    /// `value` as a single-quoted YAML scalar (internal quotes doubled), so a
    /// path cannot inject YAML.
    package static func yamlQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `content` (nil: no config file yet) with the agent's top-level path
    /// line replaced by one for `path`; every other line is kept as is.
    package static func settingPath(_ path: String, for agent: OnboardingAgentChoice.Agent, in content: String?) -> String {
        let key = agent.session.setup.pathKey
        let line = "\(key): \(yamlQuote(path))\n"
        guard let content, !content.isEmpty else { return line }
        var kept = content.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("\(key):") }
            .joined(separator: "\n")
        if !kept.hasSuffix("\n") { kept += "\n" }
        return kept + line
    }

    /// Writes `path` into the config at `configPath` (created, with its
    /// directory, when missing). The file is re-read and written inside the
    /// config write lock (`ConfigFileLock`), so a key another writer set
    /// after onboarding loaded the file survives; `ConfigFileWriter` writes it
    /// owner-only (0600) and atomically. Throws on a path with a line break,
    /// or when the config cannot be read or written.
    package static func save(
        _ path: String,
        for agent: OnboardingAgentChoice.Agent,
        configPath: String,
        access: ConfigFileAccess = .live
    ) throws {
        guard !path.contains(where: \.isNewline) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: path])
        }
        try access.withLock(configPath) { token in
            let existing = try access.read(configPath).map { data in
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: configPath])
                }
                return text
            }
            try access.write(settingPath(path, for: agent, in: existing), configPath, token)
        }
    }
}
