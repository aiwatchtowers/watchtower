import XCTest
@testable import WatchtowerDesktop

@MainActor
final class GitRefsWatcherTests: XCTestCase {
    private var root: URL!
    private var gitDir: URL!
    private var watchers: [GitRefsWatcher] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wt refs \(UUID().uuidString)", isDirectory: true)
        gitDir = root.appendingPathComponent(".git", isDirectory: true)
        for dir in ["refs/heads", "refs/remotes/origin", "objects/ab", "logs"] {
            try FileManager.default.createDirectory(at: gitDir.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
    }

    override func tearDown() {
        watchers.forEach { $0.stop() }
        watchers = []
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRelevantPaths() {
        let git = "/r/.git"
        let worktree = "/r/.git/worktrees/w"
        let yes = [
            "/r/.git/HEAD", "/r/.git/index", "/r/.git/packed-refs",
            "/r/.git/refs/heads/main", "/r/.git/refs/heads/a/b", "/r/.git/refs/remotes/origin/x",
            "/r/.git/worktrees/w/HEAD", "/r/.git/worktrees/other/HEAD", "/r/.git/worktrees/w/index"
        ]
        let no = [
            "/r/.git/objects/ab/cd", "/r/.git/logs/HEAD", "/r/.git/logs/refs/heads/main",
            "/r/.git/HEAD.lock", "/r/.git/index.lock", "/r/.git/refs/heads/main.lock",
            "/r/.git/ORIG_HEAD", "/r/.git/FETCH_HEAD", "/r/.git/refs/tags/v1", "/r/.git/refs/heads",
            "/r/.git", "/r/src/HEAD", "/r/.gitx/HEAD", "/r/.git/worktrees/w/logs/HEAD"
        ]
        for path in yes {
            XCTAssertTrue(GitRefsWatcher.isRelevant(path: path, gitDir: worktree, commonDir: git), path)
        }
        for path in no {
            XCTAssertFalse(GitRefsWatcher.isRelevant(path: path, gitDir: worktree, commonDir: git), path)
        }
    }

    func testWatchedPathsAreDeduped() {
        XCTAssertEqual(GitRefsWatcher.watchedPaths(gitDir: "/r/.git", commonDir: "/r/.git"), ["/r/.git"])
        XCTAssertEqual(GitRefsWatcher.watchedPaths(gitDir: "/r/.git/worktrees/w", commonDir: "/r/.git"), ["/r/.git"],
                       "a linked worktree's git dir is inside the common dir")
        XCTAssertEqual(GitRefsWatcher.watchedPaths(gitDir: "/elsewhere/gitdir", commonDir: "/r/.git"),
                       ["/r/.git", "/elsewhere/gitdir"])
    }

    private func watch(latency: TimeInterval = 0.1, onChange: @escaping @MainActor () -> Void) -> GitRefsWatcher {
        let watcher = GitRefsWatcher(gitDir: gitDir.path, commonDir: gitDir.path, latency: latency, onChange: onChange)
        watchers.append(watcher)
        return watcher
    }

    /// The way git updates a ref: write `<ref>.lock`, rename it into place.
    private func updateRef(_ name: String) throws {
        let ref = gitDir.appendingPathComponent(name)
        let lock = gitDir.appendingPathComponent(name + ".lock")
        try Data("0123456789abcdef0123456789abcdef01234567\n".utf8).write(to: lock)
        _ = try FileManager.default.replaceItemAt(ref, withItemAt: lock)
    }

    /// Lets fseventsd journal the fixture's own writes before a watcher
    /// starts, and a new stream get going before the test writes.
    private func settle(_ duration: Duration = .milliseconds(300)) async {
        try? await Task.sleep(for: duration)
    }

    func testARefUpdateFiresOnce() async throws {
        var fired = 0
        let first = expectation(description: "fired")
        await settle(.seconds(1))
        _ = watch { fired += 1; if fired == 1 { first.fulfill() } }
        await settle()
        try updateRef("refs/heads/x")
        await fulfillment(of: [first], timeout: 5)
        let more = expectation(description: "no second batch")
        more.isInverted = true
        await fulfillment(of: [more], timeout: 1)
        XCTAssertEqual(fired, 1)
    }

    func testObjectWritesDoNotFire() async throws {
        let never = expectation(description: "no fire")
        never.isInverted = true
        await settle(.seconds(1))
        _ = watch { never.fulfill() }
        await settle()
        try Data("blob".utf8).write(to: gitDir.appendingPathComponent("objects/ab/cd"))
        try Data("log".utf8).write(to: gitDir.appendingPathComponent("logs/HEAD"))
        await fulfillment(of: [never], timeout: 1.5)
    }

    func testStopSilencesTheWatcher() async throws {
        let never = expectation(description: "no fire after stop")
        never.isInverted = true
        await settle(.seconds(1))
        let watcher = watch { never.fulfill() }
        await settle()
        watcher.stop()
        try updateRef("refs/heads/y")
        await fulfillment(of: [never], timeout: 1.5)
    }
}
