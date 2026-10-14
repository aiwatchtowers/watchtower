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
            report("git log skipped: no git in the developer dir, the Command Line Tools or Homebrew (the /usr/bin/git shim is never run)")
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

    /// A background read's argv: the Desktop twin of Go's `gitbin.ReadArgs`
    /// (internal/gitbin/run.go — keep the two in sync). A folder's own
    /// .git/config can name commands git runs by itself (core.fsmonitor on a
    /// status, core.hooksPath, a gpg.program behind log.showSignature); a
    /// command-line -c outranks it, so a read never runs one.
    package static func readArgs(_ arguments: [String]) -> [String] {
        ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false"] + arguments
    }

    /// `readArgs` for a read of `folder`'s file content (a status): it also
    /// blanks every filter driver and git-lfs extension command the folder's
    /// config names — a `.gitattributes` `filter=<x>` would otherwise make
    /// git run filter.<x>.clean on the folder's files — and lifts a driver's
    /// `required`. The twin of Go's `gitbin.ReadArgsIn`, read fresh for each
    /// call. Only the global and system scopes are the owner's and left
    /// alone, so a repository-local `filter.lfs.*` is blanked too. nil when
    /// the drivers cannot be listed: the caller fails the read rather than
    /// run it unprotected.
    package static func readArgs(git: String, folder: URL, _ arguments: [String]) async -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = readArgs([
            "-C", folder.path, "config", "--show-scope", "-z", "--name-only", "--get-regexp", filterDriverKeys
        ])
        let listed = await ProcessPipes.run(process)
        switch listed.exitCode {
        case 0: break
        case 1: return readArgs(arguments) // no filter driver configured
        default: return nil
        }
        guard let overrides = filterOverrides(listed.stdout) else { return nil }
        return readArgs(overrides + arguments)
    }

    /// Go `gitbin.filterDriverKeys`.
    static let filterDriverKeys = #"^(filter\..*\.(clean|smudge|process)|lfs\.extension\..*\.(clean|smudge))$"#

    /// `-c <key>=` per listed key outside the global and system scopes, and
    /// `-c filter.<x>.required=false` once per driver, from `git config
    /// --show-scope -z --name-only` output (scope NUL key NUL). nil when a
    /// key cannot be overridden by `-c` (it holds a '=' or a newline).
    static func filterOverrides(_ output: String) -> [String]? {
        var fields = output.components(separatedBy: "\u{0}")
        if fields.last?.isEmpty == true { fields.removeLast() }
        var out: [String] = []
        var lifted: Set<String> = []
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index], key = fields[index + 1]
            index += 2
            if scope == "global" || scope == "system" { continue }
            let isFilter = key.hasPrefix("filter.")
            guard isFilter || key.hasPrefix("lfs.extension."), !key.contains("="), !key.contains("\n"),
                  let dot = key.lastIndex(of: ".") else { return nil }
            out += ["-c", key + "="]
            let name = String(key[..<dot])
            if isFilter, lifted.insert(name).inserted { out += ["-c", name + ".required=false"] }
        }
        return out
    }

    /// `xcode-select -p`: the active developer directory, nil when none is
    /// set. Unlike the shims it only prints, never prompts.
    static func developerDir() async -> String? {
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
        process.arguments = readArgs(arguments)
        return await ProcessPipes.run(process)
    }
}
