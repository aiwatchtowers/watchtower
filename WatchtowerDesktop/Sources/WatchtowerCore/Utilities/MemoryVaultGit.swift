import Foundation

/// Vault git-history access for the Memory browser: shells out to `git log`
/// against the vault repo (go-git on the Go side, but a normal repository on
/// disk). Read-only — the app never commits; the pipeline owns all vault
/// commits (MEM-03).
package enum MemoryVaultGit {

    /// Last 50 commits touching `path` (vault-relative), or the whole repo
    /// history when nil. Any git failure — no git (`gitPath`), corrupt repo,
    /// non-zero exit — degrades to an empty list, reported with git's stderr
    /// through `report` (the log).
    package static func log(
        vault: URL,
        path: String?,
        report: (String) -> Void = { NSLog("[MemoryVaultGit] %@", $0) }
    ) async -> [MemoryCommit] {
        var args = ["-C", vault.path, "log", "--date=iso-strict", "--format=%H%x09%ad%x09%s", "-n", "50"]
        if let path {
            args += ["--follow", "--", path]
        }
        guard let git = gitPath(developerDir: await developerDir()) else {
            report("git log skipped: no git outside the xcode-select shim (developer tools not installed)")
            return []
        }
        let result = await run(git: git, arguments: args)
        guard result.exitCode == 0 else {
            report("git log failed (exit \(result.exitCode)): \(CLILog.detail(result.stderr))")
            return []
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return MemoryCommit(hash: String(parts[0]), date: String(parts[1]), subject: String(parts[2]))
        }
    }

    /// The git binary to run, never `/usr/bin/git`: that is the xcode-select
    /// shim, and on a Mac without the Command Line Tools it pops the system
    /// "install developer tools" dialog — attributed to Watchtower — for a
    /// history that would come back empty anyway. The active developer
    /// directory's git first, then the standard CLT and Homebrew installs;
    /// nil when none is there.
    static func gitPath(
        developerDir: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let developerDir, !developerDir.isEmpty {
            candidates.append(developerDir + "/usr/bin/git")
        }
        candidates += [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git"
        ]
        return candidates.first(where: isExecutable)
    }

    /// `xcode-select -p`: the active developer directory, nil when none is
    /// set. Unlike the shims it only prints, never prompts.
    private static func developerDir() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let result = await ProcessPipes.run(process).trimmed
        return result.exitCode == 0 ? result.stdout : nil
    }

    /// Off the concurrency pool, both streams drained (`ProcessPipes`).
    private static func run(git: String, arguments: [String]) async -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        return await ProcessPipes.run(process)
    }
}
