import Foundation

enum Constants {
    static let configPath = NSString("~/.config/watchtower/config.yaml").expandingTildeInPath
    static let databasePath = NSString("~/.local/share/watchtower").expandingTildeInPath
    static let bundleID = "com.watchtower.desktop"

    /// App version — reads from Info.plist (set at build time), falls back to hardcoded default.
    static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }()

    enum NotificationCategory {
        static let decision = "DECISION"
        static let dailySummary = "DAILY_SUMMARY"
    }

    /// Read `claude_path` override from config.yaml (lightweight, no Yams dependency).
    nonisolated static func claudePathFromConfig() -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8) else { return nil }
        // Simple line-based parse: "claude_path: /some/path"
        for line in str.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("claude_path:") {
                let value = trimmed.dropFirst("claude_path:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty && FileManager.default.isExecutableFile(atPath: value) {
                    return value
                }
            }
        }
        return nil
    }

    /// Check if Claude Code CLI is available.
    nonisolated static func findClaudePath() -> String? {
        // Priority 0: explicit override from config.yaml
        if let override = claudePathFromConfig() {
            return override
        }

        let home = NSHomeDirectory()

        // Known installation paths
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/bin/claude",
            "\(home)/.volta/bin/claude",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Search versioned node managers (nvm, fnm)
        let versionedDirs = [
            "\(home)/.nvm/versions/node",
            "\(home)/.local/share/fnm/node-versions",
            "\(home)/.fnm/node-versions",
        ]
        for dir in versionedDirs {
            if let found = searchNodeVersions(dir: dir, binary: "claude") {
                return found
            }
        }

        // Fallback: which via user's login shell
        if let path = whichViashell("claude") {
            return path
        }

        return nil
    }

    /// Search versioned node manager directories for a binary.
    private nonisolated static func searchNodeVersions(dir: String, binary: String) -> String? {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for v in versions.sorted().reversed() {
            // nvm: <dir>/<version>/bin/<binary>, fnm: <dir>/<version>/installation/bin/<binary>
            for sub in ["bin", "installation/bin"] {
                let path = "\(dir)/\(v)/\(sub)/\(binary)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// Resolve a binary via `which` using the user's login shell.
    nonisolated static func whichViashell(_ binary: String) -> String? {
        // Use the user's actual shell, not hardcoded zsh
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Validate binary name to prevent shell injection
        guard binary.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        process.arguments = ["-lc", "which \(binary)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        return nil
    }

    /// Returns a process environment with the user's full PATH resolved from their login shell.
    /// Cached after first call. Useful for launching subprocesses from a macOS app (where PATH is minimal).
    nonisolated static func resolvedEnvironment() -> [String: String] {
        struct Cache {
            static let env: [String: String] = {
                var env = ProcessInfo.processInfo.environment
                let shell = env["SHELL"] ?? "/bin/zsh"
                let pathProc = Process()
                pathProc.executableURL = URL(fileURLWithPath: shell)
                pathProc.arguments = ["-lc", "echo $PATH"]
                let pathPipe = Pipe()
                pathProc.standardOutput = pathPipe
                pathProc.standardError = FileHandle.nullDevice
                try? pathProc.run()
                pathProc.waitUntilExit()
                if let fullPath = String(data: pathPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !fullPath.isEmpty {
                    env["PATH"] = fullPath
                }
                env.removeValue(forKey: "CLAUDECODE")
                return env
            }()
        }
        return Cache.env
    }

    /// Resolve the watchtower CLI binary path.
    /// Priority: app bundle → known system paths → `which` lookup.
    nonisolated static func findCLIPath() -> String? {
        // 1. Inside the app bundle
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("watchtower").path,
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        // 2. Known system paths
        let paths = [
            "/usr/local/bin/watchtower",
            "/opt/homebrew/bin/watchtower",
            NSString("~/go/bin/watchtower").expandingTildeInPath,
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 3. which via login shell (picks up user's full PATH)
        if let path = whichViashell("watchtower") {
            return path
        }

        return nil
    }
}
