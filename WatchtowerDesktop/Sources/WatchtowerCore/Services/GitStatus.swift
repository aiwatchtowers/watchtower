import Foundation

/// What `git status` says about one file, as the code viewer marks it in
/// the FILES tree and on tabs (POC). Staged and unstaged are not told apart:
/// either way the change is not committed.
package enum GitFileStatus: Equatable, Sendable {
    case modified
    case added
    case untracked
    case renamed
    case deleted
    case conflicted

    /// The tree's and the tab's badge.
    package var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .renamed: "R"
        case .deleted: "D"
        case .conflicted: "!"
        }
    }
}

/// A parsed `git status --porcelain=v2 -z` of a workbench folder: each
/// changed file by its path relative to the folder, and every folder that
/// holds one (for the folder dot).
package struct GitStatusSnapshot: Equatable, Sendable {
    package var files: [String: GitFileStatus] = [:]
    package var dirtyDirectories: Set<String> = []

    package init(files: [String: GitFileStatus] = [:]) {
        self.files = files
        for path in files.keys {
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                dirtyDirectories.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
    }

    /// `output` is porcelain v2 with -z (paths relative to the repository
    /// root, NUL-separated, a rename's original path in the next field);
    /// `prefix` is `git rev-parse --show-prefix` — the folder's path inside
    /// the repository, "" at its root. Entries outside the folder are dropped.
    package static func parse(_ output: String, prefix: String) -> Self {
        var files: [String: GitFileStatus] = [:]
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst() {
            guard let kind = field.first else { continue }
            var path: String?
            var status: GitFileStatus?
            switch kind {
            case "1":
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count == 9 { path = String(parts[8]); status = Self.status(xy: parts[1]) }
            case "2":
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                if parts.count == 10 { path = String(parts[9]); status = .renamed }
                _ = fields.popFirst() // the original path
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if parts.count == 11 { path = String(parts[10]); status = .conflicted }
            case "?":
                path = String(field.dropFirst(2))
                status = .untracked
            default:
                continue // "#" headers, "!" ignored
            }
            guard let path, let status, path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if !relative.isEmpty { files[relative] = status }
        }
        return Self(files: files)
    }

    /// X (index) and Y (worktree) of an ordinary entry, "." = unchanged.
    private static func status(xy: Substring) -> GitFileStatus {
        let codes = Set(xy)
        if codes.contains("D") { return .deleted }
        if codes.contains("A") { return .added }
        if codes.contains("R") || codes.contains("C") { return .renamed }
        return .modified
    }
}

extension GitStatusSnapshot {
    /// Reads `folder`'s status; nil when it is not inside a repository or
    /// no git is installed (found the way `MemoryVaultGit` finds it, never
    /// the /usr/bin/git shim that pops the developer-tools dialog).
    /// `--no-optional-locks` keeps this background read from taking
    /// index.lock under a commit the agent is making.
    package static func read(folder: URL) async -> Self? {
        guard let git = MemoryVaultGit.gitPath(developerDir: await MemoryVaultGit.developerDir()) else { return nil }
        let prefix = await run(git, ["-C", folder.path, "rev-parse", "--show-prefix"])
        guard prefix.exitCode == 0 else { return nil }
        let status = await run(git, [
            "--no-optional-locks", "-C", folder.path, "status", "--porcelain=v2", "-z", "--untracked-files=all", "--", "."
        ])
        guard status.exitCode == 0 else { return nil }
        return parse(status.stdout, prefix: prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ git: String, _ arguments: [String]) async -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        return await ProcessPipes.run(process)
    }
}
