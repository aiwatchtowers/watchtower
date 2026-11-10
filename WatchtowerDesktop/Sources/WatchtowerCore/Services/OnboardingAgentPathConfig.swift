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
    /// directory, when missing). The new content goes to an owner-only (0600:
    /// the file holds secrets) sibling first and is renamed over the config,
    /// so the config is never readable by others nor half-written. Throws on
    /// a path with a line break, or when the config cannot be read or written.
    package static func save(_ path: String, for agent: OnboardingAgentChoice.Agent, configPath: String) throws {
        guard !path.contains(where: \.isNewline) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: path])
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let existing = fileManager.fileExists(atPath: configPath)
            ? try String(contentsOfFile: configPath, encoding: .utf8)
            : nil
        let staged = configPath + ".tmp-\(UUID().uuidString)"
        // Created 0600 (not chmod-ed after the write), so the secrets are
        // never on disk with a looser mode.
        let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(settingPath(path, for: agent, in: existing).utf8))
            try handle.close()
            guard rename(staged, configPath) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fileManager.removeItem(atPath: staged)
            throw error
        }
    }
}
