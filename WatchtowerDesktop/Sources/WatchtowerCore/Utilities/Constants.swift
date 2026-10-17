import Foundation
import Yams

package enum Constants {
    /// `WATCHTOWER_CONFIG_PATH` lets a dev/verification run point the app at
    /// an isolated config.yaml instead of the real one, without touching it —
    /// mirrors ConfigService's existing test-friendly `init(configPath:)`.
    package static let configPath = ProcessInfo.processInfo.environment["WATCHTOWER_CONFIG_PATH"]
        ?? NSString("~/.config/watchtower/config.yaml").expandingTildeInPath

    package static let databasePath = NSString("~/.local/share/watchtower").expandingTildeInPath
    package static let bundleID = "com.watchtower.desktop"
    package static let configDir = NSString("~/.config/watchtower").expandingTildeInPath
    /// UserDefaults key of the opt-in mobile hub toggle (Settings → Mobile,
    /// off by default in every flavor; mobile POC spec §6.1).
    package static let mobileSyncEnabledKey = "mobileSyncEnabled"

    /// Directory of the active workspace: `active_workspace` from config.yaml,
    /// or — when the key is missing — the one workspace directory holding a
    /// `watchtower.db`, nil otherwise. Connection checks must use this instead
    /// of scanning all workspace dirs for a first match — a stale token left in
    /// an old workspace would otherwise show the active one as connected; the
    /// single-candidate fallback has no such ambiguity by construction.
    package nonisolated static func activeWorkspaceDir() -> String? {
        if let workspace = configuredActiveWorkspace() {
            return "\(databasePath)/\(workspace)"
        }
        guard let workspace = singleWorkspaceWithDatabase(under: databasePath) else { return nil }
        return "\(databasePath)/\(workspace)"
    }

    nonisolated private static func configuredActiveWorkspace() -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any],
              let workspace = yaml["active_workspace"] as? String,
              !workspace.isEmpty else { return nil }
        return workspace
    }

    /// The Go-side rule mirrored (`config.resolveActiveWorkspace`, a deliberate
    /// dual-path pinned on both sides): the name of the single directory under
    /// `root` that passes the Go workspace-name check and holds a
    /// `watchtower.db`. Zero or several candidates → nil; the CLI refuses to
    /// guess between several, so the Desktop must not either. `fileExists`
    /// follows a symlinked workspace directory; Go's
    /// `workspaceDirsWithDatabase` stats through it the same way.
    package nonisolated static func singleWorkspaceWithDatabase(under root: String) -> String? {
        let candidates = workspacesWithDatabase(under: root)
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Every directory under `root` that passes the Go workspace-name check and
    /// holds a `watchtower.db`, sorted — the candidate set both
    /// `singleWorkspaceWithDatabase` and `DatabaseManager.resolveDBPath` decide
    /// on. An unlistable or missing `root` yields no candidates.
    package nonisolated static func workspacesWithDatabase(under root: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let candidates = entries.filter { name in
            isWorkspaceName(name) && fm.fileExists(atPath: "\(root)/\(name)/watchtower.db")
        }
        return candidates.sorted()
    }

    /// Go's `config.ValidWorkspaceRe`: ASCII letters, digits, `.`, `_`, `-`,
    /// starting with a letter or digit. Stricter than
    /// `DatabaseManager.isValidWorkspaceName`, which only guards paths.
    package nonisolated static func isWorkspaceName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }

    /// Whether the Phase-4 memory surface for the Discuss chat is enabled
    /// (`memory.surfaces.chat` in config.yaml). Default false — the whole
    /// memory-in-prompt injection is dark unless the owner opts in. Read
    /// nonisolated (Yams parse, mirror of `activeWorkspaceDir()`) so the
    /// `nonisolated static` prompt builder can consult it without hopping actors.
    package nonisolated static func memorySurfacesChatEnabled() -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any],
              let memory = yaml["memory"] as? [String: Any],
              let surfaces = memory["surfaces"] as? [String: Any],
              let chat = surfaces["chat"] as? Bool else { return false }
        return chat
    }

    /// The AI provider id (`ai.provider` in config.yaml), defaulting to
    /// `"claude"` when unset. The target chat's `toolsAvailable` derives from
    /// this — the only case a chat-mode call reaches no tools is the app-wide
    /// Ollama provider (Ollama has no MCP tool support).
    package nonisolated static func aiProviderID() -> String {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any],
              let ai = yaml["ai"] as? [String: Any],
              let provider = ai["provider"] as? String, !provider.isEmpty else { return "claude" }
        return provider
    }

    /// The memory vault directory for the active workspace
    /// (`<activeWorkspaceDir>/memory`), or nil when no workspace is active.
    /// The hot `map.md` lives directly under it.
    package nonisolated static func memoryVaultDir() -> String? {
        guard let workspaceDir = activeWorkspaceDir() else { return nil }
        return "\(workspaceDir)/memory"
    }

    /// Safe working directory for subprocesses — avoids TCC prompts for ~/Music, ~/Downloads etc.
    /// Uses ~/.config/watchtower (already ours, not TCC-protected).
    package nonisolated static func processWorkingDirectory() -> URL {
        let dir = configDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return URL(fileURLWithPath: dir)
    }

    /// App version — reads from Info.plist (set at build time), falls back to hardcoded default.
    /// A leading "v"/"V" is stripped here (not just at the one display call
    /// site that surfaced it) so every caller — including the ones that
    /// prepend their own "v" — is protected against a build invoked with a
    /// "v"-prefixed VERSION (e.g. copied from a git tag).
    package static let appVersion: String = {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        return Self.stripLeadingV(raw)
    }()

    package static func stripLeadingV(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    package enum NotificationCategory {
        static let decision = "DECISION"
        static let dailySummary = "DAILY_SUMMARY"
    }

    /// Search for a binary in well-known directories first, then resolved PATH.
    /// Well-known dirs are checked first to avoid TCC prompts from iterating
    /// the full PATH (which may include ~/Documents, ~/Music, etc.).
    package nonisolated static func findInPath(_ binary: String) -> String? {
        let home = NSHomeDirectory()

        // 1. Well-known directories — fast, no TCC risk
        let knownDirs = [
            "\(home)/.local/bin",
            "\(home)/.claude/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.volta/bin"
        ]
        for dir in knownDirs {
            let fullPath = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        // 2. Scan nvm/fnm versioned directories
        let versionedDirs = [
            "\(home)/.nvm/versions/node",
            "\(home)/.local/share/fnm/node-versions",
            "\(home)/.fnm/node-versions"
        ]
        for dir in versionedDirs {
            if let found = searchNodeVersions(dir: dir, binary: binary) {
                return found
            }
        }

        // 3. Resolved PATH — skip TCC-protected directories
        let tccProtected: Set<String> = [
            "\(home)/Documents", "\(home)/Downloads", "\(home)/Desktop",
            "\(home)/Music", "\(home)/Movies", "\(home)/Pictures"
        ]
        let env = resolvedEnvironment()
        guard let pathValue = env["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") {
            let dirStr = String(dir)
            if tccProtected.contains(where: { dirStr.hasPrefix($0) }) { continue }
            let fullPath = "\(dirStr)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        return nil
    }

    /// Search versioned node manager directories for a binary.
    nonisolated private static func searchNodeVersions(dir: String, binary: String) -> String? {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for ver in versions.sorted().reversed() {
            for sub in ["bin", "installation/bin"] {
                let path = "\(dir)/\(ver)/\(sub)/\(binary)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// Resolves `resolvedEnvironment()` once on a thread of its own, at launch:
    /// the first call runs the login shell (up to 5 s) and every caller waits
    /// on it, which must not happen on a Swift-concurrency pool thread (see
    /// `ProcessPipes`) or on the main thread.
    package nonisolated static func prewarmResolvedEnvironment() {
        Thread.detachNewThread { _ = resolvedEnvironment() }
    }

    /// The login-shell probe `resolvedEnvironment` runs: each value on a
    /// line of its own behind a marker, so anything the shell's startup
    /// files print is ignored. Plain `"$VAR"` expansions, which zsh, bash and
    /// fish all read the same way.
    package nonisolated static let loginShellProbe =
        #"printf '\#(probePathMarker)%s\n\#(probeCodexHomeMarker)%s\n' "$PATH" "$CODEX_HOME""#
    nonisolated private static let probePathMarker = "WATCHTOWER_PROBE_PATH="
    nonisolated private static let probeCodexHomeMarker = "WATCHTOWER_PROBE_CODEX_HOME="

    /// The probe's output read back: PATH, and CODEX_HOME (spec 2026-10-12
    /// §7: the Codex the login shell launches reads it, so the trust step,
    /// the status check and the rollout lookup must too). An empty or
    /// missing value is nil.
    package nonisolated static func parseLoginShellProbe(_ output: String) -> (path: String?, codexHome: String?) {
        var path: String?, codexHome: String?
        for line in output.split(whereSeparator: \.isNewline) {
            if let value = line.trimmedSuffix(after: probePathMarker) { path = value }
            if let value = line.trimmedSuffix(after: probeCodexHomeMarker) { codexHome = value }
        }
        return (path, codexHome)
    }

    /// `resolvedEnvironment()` once it has been resolved (the launch-time
    /// prewarm), else the app's own environment. Never runs the login
    /// shell, so the MainActor can call it without blocking.
    package nonisolated static func resolvedEnvironmentIfReady() -> [String: String] {
        resolvedEnvironmentBox.get() ?? ProcessInfo.processInfo.environment
    }

    /// `resolvedEnvironment()` without blocking the caller: the resolved
    /// value at once when the launch-time prewarm is done, else awaited on a
    /// thread of its own (never a pool or main thread, see
    /// `prewarmResolvedEnvironment`). For async callers that want the login
    /// shell's PATH and CODEX_HOME, not the app's own fallback.
    package nonisolated static func resolvedEnvironmentAsync() async -> [String: String] {
        if let env = resolvedEnvironmentBox.get() { return env }
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: resolvedEnvironment()) }
        }
    }

    nonisolated private static let resolvedEnvironmentBox = ResolvedEnvironmentBox()

    /// Returns a process environment with the user's full PATH — and their
    /// CODEX_HOME, when the login shell sets one — resolved from their login
    /// shell. Cached after first call. Useful for launching subprocesses from
    /// a macOS app (where PATH is minimal).
    package nonisolated static func resolvedEnvironment() -> [String: String] {
        enum Cache {
            /// answered: the login shell printed the probe (it did not
            /// time out or fail), so PATH and CODEX_HOME are its own.
            static let resolved = Constants.probeLoginShell()
        }
        resolvedEnvironmentBox.set(Cache.resolved.env)
        if Cache.resolved.answered { answeredEnvironmentBox.set(Cache.resolved.env) }
        return Cache.resolved.env
    }

    /// One run of the login-shell probe (up to 5 s): the app's environment
    /// with the shell's PATH and CODEX_HOME; answered is false when the shell
    /// timed out or printed no probe line.
    nonisolated private static func probeLoginShell() -> (env: [String: String], answered: Bool) {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let pathProc = Process()
        pathProc.executableURL = URL(fileURLWithPath: shell)
        let configDir = NSString("~/.config/watchtower").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        pathProc.currentDirectoryURL = URL(fileURLWithPath: configDir)
        pathProc.arguments = ["-lc", Self.loginShellProbe]
        let pathPipe = Pipe()
        pathProc.standardOutput = pathPipe
        pathProc.standardError = FileHandle.nullDevice
        try? pathProc.run()
        // Timeout: kill after 5s to avoid hanging on broken shell configs
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { pathProc.terminate() }
        timer.resume()
        pathProc.waitUntilExit()
        timer.cancel()
        let probed = Self.parseLoginShellProbe(
            String(data: pathPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
        if let fullPath = probed.path { env["PATH"] = fullPath }
        if let codexHome = probed.codexHome { env["CODEX_HOME"] = codexHome }
        env = withoutAgentMarkers(env)
        // Ensure claude's nvm/fnm dir is in PATH (login-only shell may miss .zshrc).
        let nvmDirs = [
            NSHomeDirectory() + "/.nvm/versions/node",
            NSHomeDirectory() + "/.local/share/fnm/node-versions",
            NSHomeDirectory() + "/.fnm/node-versions"
        ]
        outer: for nvmDir in nvmDirs {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else { continue }
            for ver in versions.sorted().reversed() {
                for sub in ["bin", "installation/bin"] {
                    let candidate = "\(nvmDir)/\(ver)/\(sub)/claude"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        let claudeDir = (candidate as NSString).deletingLastPathComponent
                        if let path = env["PATH"], !path.contains(claudeDir) {
                            env["PATH"] = claudeDir + ":" + path
                        }
                        break outer
                    }
                }
            }
        }
        return (env, probed.path != nil)
    }

    /// The variables an AI coding agent's shell carries — keep in sync with
    /// `agentEnvMarkers` in cmd/actions.go. The CLI refuses an approve or an
    /// apply while any is set (AGENT-07), so the app, when launched from such
    /// a shell, must not hand them to the `watchtower` it runs for the owner.
    /// WATCHTOWER_AUTOMATION_RUN_ID marks a child an automation run started.
    package nonisolated static let agentEnvMarkers = [
        "CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX", "WATCHTOWER_TERMINAL_SESSION_ID",
        "WATCHTOWER_AUTOMATION_RUN_ID"
    ]

    package nonisolated static func withoutAgentMarkers(_ env: [String: String]) -> [String: String] {
        env.filter { !agentEnvMarkers.contains($0.key) }
    }

    /// `resolvedEnvironment()`'s value when the login shell answered it.
    nonisolated private static let answeredEnvironmentBox = ResolvedEnvironmentBox()

    /// The login shell's environment for callers about to act on CODEX_HOME
    /// (`resolvedLoginEnvironment`): the launch-time resolve when the shell
    /// answered it, else a fresh probe — a failure is never cached, so a
    /// later call probes again.
    nonisolated private static let loginEnvironmentResolver = LoginEnvironmentResolver {
        _ = resolvedEnvironment() // the launch-time resolve, cached
        if let answered = answeredEnvironmentBox.get() { return answered }
        let again = probeLoginShell()
        return again.answered ? again.env : nil
    }

    /// The login shell's environment, resolved on a thread of its own (never
    /// a pool or main thread, see `prewarmResolvedEnvironment`); nil when the
    /// login shell did not answer the probe, so a caller about to act on
    /// CODEX_HOME knows it does not have the shell's value. Retried on the
    /// next call until it answers once.
    package nonisolated static func resolvedLoginEnvironment() async -> [String: String]? {
        await loginEnvironmentResolver.resolve()
    }

    /// The CLI binary shipped inside the app bundle. Live processes must not
    /// run from this path — rebuilds overwrite it (see CLIBinaryStore).
    package nonisolated static func bundledCLIPath() -> String? {
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("watchtower").path,
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        return nil
    }

    /// The `watchtower-ocr` helper shipped next to the bundled CLI (nil for
    /// `swift run`/`swift test`, and for a bundle built before the helper).
    package nonisolated static func bundledOCRHelperPath() -> String? {
        if let path = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("watchtower-ocr").path,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Resolve the watchtower CLI binary path.
    /// Priority: Application Support store copy → app bundle → resolved PATH.
    /// The store copy is used only while it matches the bundled CLI (the
    /// verdict is cached against the files' on-disk identity, see
    /// `CLIBinaryStore.resolvedInstalledPath`); a stale or
    /// tampered copy falls through to the bundle, and a dev run with no bundled
    /// CLI ignores the store entirely and resolves via PATH.
    package nonisolated static func findCLIPath() -> String? {
        if let store = CLIBinaryStore.resolvedInstalledPath() { return store }
        if let bundled = bundledCLIPath() { return bundled }
        return findInPath("watchtower")
    }
}

private extension Substring {
    /// The rest of the line after `marker`, trimmed; nil when the line does
    /// not start with it or nothing follows.
    func trimmedSuffix(after marker: String) -> String? {
        guard hasPrefix(marker) else { return nil }
        let value = dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// The resolved environment, once a `resolvedEnvironment()` call returned
/// it; the first value set stays.
package final class ResolvedEnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var env: [String: String]?

    package init() {}

    package func get() -> [String: String]? {
        lock.withLock { env }
    }

    package func set(_ value: [String: String]) {
        lock.withLock { if env == nil { env = value } }
    }
}

/// Resolves the login shell's environment with `probe` on a thread of its
/// own; caches the first answer for good, never a failure (nil), so a
/// later `resolve()` probes again.
package final class LoginEnvironmentResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var env: [String: String]?
    private let probe: @Sendable () -> [String: String]?

    package init(probe: @escaping @Sendable () -> [String: String]?) {
        self.probe = probe
    }

    package func resolve() async -> [String: String]? {
        if let env = lock.withLock({ env }) { return env }
        let probed = await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: self.probe()) }
        }
        if let probed { lock.withLock { if env == nil { env = probed } } }
        return probed
    }
}
