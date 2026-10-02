import Foundation

/// The onboarding Claude step's `config.yaml` edit: pins `claude_path` to a
/// binary the owner picked by hand.
package enum OnboardingClaudePathConfig {
    /// `value` as a single-quoted YAML scalar (internal quotes doubled), so a
    /// path cannot inject YAML.
    package static func yamlQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// `content` (nil: no config file yet) with its top-level `claude_path`
    /// line replaced by one for `path`; every other line is kept as is.
    package static func settingClaudePath(_ path: String, in content: String?) -> String {
        let line = "claude_path: \(yamlQuote(path))\n"
        guard let content, !content.isEmpty else { return line }
        var kept = content.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("claude_path:") }
            .joined(separator: "\n")
        if !kept.hasSuffix("\n") { kept += "\n" }
        return kept + line
    }

    /// Writes `path` into the config at `configPath` (created, with its
    /// directory, when missing). The new content goes to an owner-only (0600:
    /// the file holds secrets) sibling first and is renamed over the config,
    /// so the config is never readable by others nor half-written. Throws on
    /// a path with a line break, or when the config cannot be read or written.
    package static func save(_ path: String, configPath: String) throws {
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
        guard fileManager.createFile(
            atPath: staged,
            contents: Data(settingClaudePath(path, in: existing).utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged])
        }
        guard rename(staged, configPath) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fileManager.removeItem(atPath: staged)
            throw error
        }
    }
}
