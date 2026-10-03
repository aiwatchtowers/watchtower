import Foundation

/// A workbench folder's GitHub repository, read from its git `origin`
/// remote, so the Session view can link a pull request (spec
/// 2026-10-03-workbench-session-report, Revision 3 "Part 7 — PR links").
/// No network: only the remote's URL is read.
package enum GitHubRemote {
    /// The repository's web URL for `remote`, "https://github.com/acme/app":
    /// the https form (`https://github.com/acme/app.git`), the scp-like ssh
    /// form (`git@<host>:owner/repo.git`) and the ssh URL form
    /// (`ssh://git@<host>/owner/repo`) on the github.com host. Nil for any
    /// other host or shape.
    package static func repositoryURL(remote: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if let url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["https", "http", "ssh", "git"].contains(scheme) {
            guard url.host?.lowercased() == "github.com" else { return nil }
            path = Substring(url.path)
        } else if let colon = trimmed.firstIndex(of: ":"), !trimmed.contains("://") {
            let host = trimmed[..<colon].split(separator: "@").last.map { $0.lowercased() }
            guard host == "github.com" else { return nil }
            path = trimmed[trimmed.index(after: colon)...]
        } else {
            return nil
        }
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
    }

    /// "https://github.com/acme/app/pull/147".
    package static func pullRequestURL(repository: URL, number: Int64) -> URL {
        repository.appendingPathComponent("pull").appendingPathComponent(String(number))
    }

    /// `git remote get-url origin` in `folder`; nil without git, outside a
    /// repository or with no `origin`. git is found the way `MemoryVaultGit`
    /// finds it, never the /usr/bin/git shim.
    package static func readOrigin(folder: URL) async -> String? {
        guard let git = MemoryVaultGit.gitPath(developerDir: await MemoryVaultGit.developerDir()) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", folder.path, "remote", "get-url", "origin"]
        let result = await ProcessPipes.run(process).trimmed
        return result.exitCode == 0 && !result.stdout.isEmpty ? result.stdout : nil
    }
}
