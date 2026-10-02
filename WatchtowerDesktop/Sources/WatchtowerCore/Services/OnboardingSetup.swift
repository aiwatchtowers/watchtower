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
    /// directory, when missing), owner-only (0600: the file holds secrets).
    /// Throws when the file cannot be read, written or locked down.
    package static func save(_ path: String, configPath: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let existing = fileManager.fileExists(atPath: configPath)
            ? try String(contentsOfFile: configPath, encoding: .utf8)
            : nil
        try settingClaudePath(path, in: existing).write(toFile: configPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }
}

/// The onboarding sync banner's progress and ETA, fed by the
/// `sync --progress-json` lines. The ETA restarts with each phase and
/// extrapolates that phase's own rate.
package struct OnboardingSyncProgress {
    package private(set) var etaSeconds: Double?
    private var lastPhase: String?
    private var phaseStartedAt: Date?

    package init() {}

    /// Folds one progress line in, observed at `now`.
    package mutating func update(_ progress: SyncProgressData, now: Date = Date()) {
        guard progress.phase == lastPhase, let phaseStartedAt else {
            lastPhase = progress.phase
            phaseStartedAt = now
            etaSeconds = nil
            return
        }
        let (done, total) = Self.phaseCounts(progress)
        let elapsed = now.timeIntervalSince(phaseStartedAt)
        // Too early in the phase (or nothing done yet) for a stable rate.
        guard done > 0, total > 0, elapsed > 2 else {
            etaSeconds = nil
            return
        }
        etaSeconds = Double(total - done) / (Double(done) / elapsed)
    }

    /// The done/total pair of the phase `progress` is in; (0, 0) for a
    /// phase without a count.
    package static func phaseCounts(_ progress: SyncProgressData) -> (done: Int, total: Int) {
        switch progress.phase {
        case "Discovery": (progress.discoveryPages, progress.discoveryTotalPages)
        case "Messages": (progress.msgChannelsDone, progress.msgChannelsTotal)
        case "Users": (progress.userProfilesDone, progress.userProfilesTotal)
        case "Threads": (progress.threadsDone ?? 0, progress.threadsTotal ?? 0)
        default: (0, 0)
        }
    }

    package static func formatElapsed(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }

    package static func formatETA(_ seconds: Double) -> String {
        let whole = Int(seconds)
        if whole < 5 { return "< 5s" }
        if whole < 60 { return "~\(whole)s" }
        let minutes = whole / 60, rest = whole % 60
        return rest == 0 ? "~\(minutes)m" : "~\(minutes)m \(rest)s"
    }
}
