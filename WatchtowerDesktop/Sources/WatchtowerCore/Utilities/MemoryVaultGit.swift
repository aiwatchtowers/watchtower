import Foundation

/// Vault git-history access for the Memory browser: shells out to `git log`
/// against the vault repo (go-git on the Go side, but a normal repository on
/// disk). Read-only — the app never commits; the pipeline owns all vault
/// commits (MEM-03).
package enum MemoryVaultGit {

    /// Last 50 commits touching `path` (vault-relative), or the whole repo
    /// history when nil. Any git failure — missing binary, corrupt repo,
    /// non-zero exit — degrades to an empty list.
    package static func log(vault: URL, path: String?) async -> [MemoryCommit] {
        var args = ["-C", vault.path, "log", "--date=iso-strict", "--format=%H%x09%ad%x09%s", "-n", "50"]
        if let path {
            args += ["--follow", "--", path]
        }
        let result = await run(arguments: args)
        guard result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return MemoryCommit(hash: String(parts[0]), date: String(parts[1]), subject: String(parts[2]))
        }
    }

    private static func run(arguments: [String]) async -> (exitCode: Int32, stdout: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe
                // Discard stderr outright: an unread Pipe that fills its buffer
                // would block git and deadlock waitUntilExit.
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, ""))
                    return
                }
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, out))
            }
        }
    }
}
