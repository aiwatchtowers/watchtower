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

    func testOutsideARepositoryIsNoRepository() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let read = await GitStatusSnapshot.read(folder: dir)
        XCTAssertEqual(read, .noRepository)
    }
}
