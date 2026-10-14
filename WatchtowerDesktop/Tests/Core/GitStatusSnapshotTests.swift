import XCTest
@testable import WatchtowerCore

final class GitStatusSnapshotTests: XCTestCase {
    private let objectID = "4286f428e3b19fe84de503916ce0e7dc8deefea1"

    private func ordinary(_ xy: String, _ path: String) -> String {
        "1 \(xy) N... 100644 100644 100644 \(objectID) \(objectID) \(path)"
    }

    func testParsesEveryEntryKind() {
        let output = [
            "# branch.oid \(objectID)",
            ordinary(".M", "a.go"),
            ordinary("M.", "staged.go"),
            ordinary("A.", "added.go"),
            ordinary(".D", "gone.go"),
            "2 RM N... 100644 100644 100644 \(objectID) \(objectID) R100 new name.go", "old name.go",
            "u UU N... 100644 100644 100644 100644 \(objectID) \(objectID) \(objectID) conflict.go",
            "? dir/new file ü.txt",
            "! ignored.log"
        ].joined(separator: "\0") + "\0"
        let snapshot = GitStatusSnapshot.parse(output, prefix: "")
        XCTAssertEqual(snapshot.files, [
            "a.go": .modified,
            "staged.go": .modified,
            "added.go": .added,
            "gone.go": .deleted,
            "new name.go": .renamed,
            "conflict.go": .conflicted,
            "dir/new file ü.txt": .untracked
        ])
    }

    func testStripsTheFolderPrefixAndDropsOutsideEntries() {
        let output = [ordinary(".M", "root.txt"), "? sub/d/x.txt", ordinary(".M", "sub/a.go")].joined(separator: "\0")
        let snapshot = GitStatusSnapshot.parse(output, prefix: "sub/")
        XCTAssertEqual(snapshot.files, ["d/x.txt": .untracked, "a.go": .modified])
    }

    func testEveryAncestorFolderIsDirty() {
        let snapshot = GitStatusSnapshot(files: ["a/b/c.go": .modified, "top.go": .untracked])
        XCTAssertEqual(snapshot.dirtyDirectories, ["a", "a/b"])
    }

    func testEmptyOutputIsClean() {
        XCTAssertEqual(GitStatusSnapshot.parse("", prefix: ""), GitStatusSnapshot())
    }
}

/// `read` against a real repository: the folder is a subdirectory, so the
/// prefix is stripped and the parent's changes stay out. Skipped without git.
final class GitStatusSnapshotReadTests: XCTestCase {
    func testReadsASubfolderOfARepository() async throws {
        guard let git = MemoryVaultGit.gitPath(developerDir: await MemoryVaultGit.developerDir()) else {
            throw XCTSkip("no git")
        }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gitstatus-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        let sub = repo.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub.appendingPathComponent("d"), withIntermediateDirectories: true)
        try "a\n".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "r\n".write(to: repo.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.email=a@example.com", "-c", "user.name=a", "commit", "-qm", "i"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", repo.path] + args
            // The developer's global config (signing, hooks) stays out.
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            let result = await ProcessPipes.run(process)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }
        try "b\n".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "n\n".write(to: sub.appendingPathComponent("d/new file.txt"), atomically: true, encoding: .utf8)
        try "z\n".write(to: repo.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)

        guard case let .snapshot(snapshot) = await GitStatusSnapshot.read(folder: sub) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.files, ["a.txt": .modified, "d/new file.txt": .untracked])
        XCTAssertEqual(snapshot.dirtyDirectories, ["d"])
    }

    /// The folder's .git/config names an fsmonitor command: the background
    /// status read must not run it (the -c overrides of `readArgs`).
    func testReadRunsNoFsmonitorCommandFromTheRepository() async throws {
        guard let git = MemoryVaultGit.gitPath(developerDir: await MemoryVaultGit.developerDir()) else {
            throw XCTSkip("no git")
        }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gitfsmon-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let marker = repo.appendingPathComponent("ran")
        let hook = repo.appendingPathComponent("fsmonitor.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        for args in [["init", "-q"], ["config", "core.fsmonitor", hook.path]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", repo.path] + args
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            let result = await ProcessPipes.run(process)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }

        guard case .snapshot = await GitStatusSnapshot.read(folder: repo) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran the repository's fsmonitor command")
    }

    /// A filter driver the folder's config names (every file routed to it by
    /// .gitattributes, `required` set) never runs from the status read, and
    /// the read still answers.
    func testReadRunsNoFilterDriverFromTheRepository() async throws {
        guard let git = MemoryVaultGit.gitPath(developerDir: await MemoryVaultGit.developerDir()) else {
            throw XCTSkip("no git")
        }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gitfilter-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let marker = repo.appendingPathComponent("ran")
        let filter = repo.appendingPathComponent("filter.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\ncat\n".write(to: filter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filter.path)
        for args in [
            ["init", "-q"], ["add", "a.txt"],
            ["-c", "user.email=a@example.com", "-c", "user.name=a", "commit", "-qm", "i"],
            ["config", "filter.planted.clean", filter.path], ["config", "filter.planted.required", "true"]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-C", repo.path] + args
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            let result = await ProcessPipes.run(process)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }
        try "* filter=planted\n".write(to: repo.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        // Same size as the commit: only hashing the content tells it changed.
        try "HELLO\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        guard case let .snapshot(snapshot) = await GitStatusSnapshot.read(folder: repo) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.files["a.txt"], .modified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "git ran the repository's filter driver")
    }

    func testFilterOverridesSkipTheOwnersScopesAndRefuseAnUnoverridableKey() {
        let listed = "local\u{0}filter.planted.clean\u{0}local\u{0}filter.planted.process\u{0}"
            + "global\u{0}filter.lfs.clean\u{0}command\u{0}filter.env.smudge\u{0}"
        XCTAssertEqual(MemoryVaultGit.filterOverrides(listed), [
            "-c", "filter.planted.clean=", "-c", "filter.planted.required=false", "-c", "filter.planted.process=",
            "-c", "filter.env.smudge=", "-c", "filter.env.required=false"
        ])
        XCTAssertEqual(MemoryVaultGit.filterOverrides(""), [])
        XCTAssertNil(MemoryVaultGit.filterOverrides("local\u{0}filter.a=b.clean\u{0}"))
    }

    func testReadArgsMirrorGitbin() {
        XCTAssertEqual(
            MemoryVaultGit.readArgs(["status"]),
            ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false", "status"]
        )
    }

    func testOutsideARepositoryIsNoRepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let read = await GitStatusSnapshot.read(folder: dir)
        XCTAssertEqual(read, .noRepository)
    }
}
