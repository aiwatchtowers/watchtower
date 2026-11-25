import CoreServices
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

    private typealias Flags = FSEventStreamEventFlags

    private func notifies(_ path: String, flag: Int, id: FSEventStreamEventId, start: FSEventStreamEventId = 100) -> Bool {
        GitRefsWatcher.shouldNotify(paths: [path], flags: [Flags(flag)], ids: [id], startEventID: start,
                                    gitDir: "/r/.git", commonDir: "/r/.git")
    }

    /// RootChanged comes with event id 0: the rescan flag must win over the
    /// "older than the stream" filter, or a renamed or recreated `.git`
    /// goes unnoticed.
    func testARescanNotifiesWhateverItsEventID() {
        XCTAssertTrue(notifies("/r/.git", flag: kFSEventStreamEventFlagRootChanged, id: 0))
        XCTAssertTrue(notifies("/r/.git", flag: kFSEventStreamEventFlagMustScanSubDirs, id: 0))
        XCTAssertTrue(notifies("/r/.git/objects", flag: kFSEventStreamEventFlagMustScanSubDirs, id: 500))
    }

    func testAnOrdinaryEventNeedsANewIDAndARelevantPath() {
        let none = kFSEventStreamEventFlagNone
        XCTAssertTrue(notifies("/r/.git/HEAD", flag: none, id: 101))
        XCTAssertFalse(notifies("/r/.git/HEAD", flag: none, id: 100), "not newer than the stream's start")
        XCTAssertFalse(notifies("/r/.git/HEAD", flag: none, id: 7))
        XCTAssertFalse(notifies("/r/.git/objects/ab/cd", flag: none, id: 101))
        XCTAssertFalse(GitRefsWatcher.shouldNotify(paths: [], flags: [], ids: [], startEventID: 0,
                                                   gitDir: "/r/.git", commonDir: "/r/.git"))
    }

    func testOneRelevantEventInABatchIsEnough() {
        XCTAssertTrue(GitRefsWatcher.shouldNotify(
            paths: ["/r/.git/objects/ab/cd", "/r/.git/refs/heads/main"],
            flags: [Flags(kFSEventStreamEventFlagNone), Flags(kFSEventStreamEventFlagNone)],
            ids: [101, 102], startEventID: 100, gitDir: "/r/.git", commonDir: "/r/.git"
        ))
    }

    /// Board #565: only a batch that may move another worktree's branch
    /// re-reads the sessions' worktree places.
    func testOnlyRefsAndOtherWorktreesMayMoveWorktrees() {
        let none = Flags(kFSEventStreamEventFlagNone)
        func moves(_ paths: [String], gitDir: String = "/r/.git", flag: Flags? = nil, id: FSEventStreamEventId = 101) -> Bool {
            GitRefsWatcher.mayMoveWorktrees(paths: paths, flags: paths.map { _ in flag ?? none },
                                            ids: paths.map { _ in id }, startEventID: 100,
                                            gitDir: gitDir, commonDir: "/r/.git")
        }
        XCTAssertFalse(moves(["/r/.git/HEAD", "/r/.git/index"]), "the folder's own HEAD and index")
        XCTAssertFalse(moves(["/r/.git/worktrees/w/HEAD", "/r/.git/worktrees/w/index"], gitDir: "/r/.git/worktrees/w"),
                       "a linked folder's own HEAD and index")
        XCTAssertTrue(moves(["/r/.git/index", "/r/.git/refs/heads/feature"]))
        XCTAssertTrue(moves(["/r/.git/packed-refs"]))
        XCTAssertTrue(moves(["/r/.git/worktrees/mobile-a/HEAD"]))
        XCTAssertTrue(moves(["/r/.git/HEAD"], gitDir: "/r/.git/worktrees/w"), "the main folder's HEAD seen from a worktree")
        XCTAssertFalse(moves(["/r/.git/refs/heads/feature"], id: 100), "not newer than the stream's start")
        XCTAssertTrue(moves(["/r/.git"], flag: Flags(kFSEventStreamEventFlagRootChanged), id: 0))
    }

    func testWatchedPathsAreDeduped() {
        XCTAssertEqual(GitRefsWatcher.watchedPaths(gitDir: "/r/.git", commonDir: "/r/.git"), ["/r/.git"])
        XCTAssertEqual(GitRefsWatcher.watchedPaths(gitDir: "/r/.git/worktrees/w", commonDir: "/r/.git"), ["/r/.git"],
                       "a linked worktree's git dir is inside the common dir")
        XCTAssertEqual(GitRefsWatcher.watchedPaths(gitDir: "/elsewhere/gitdir", commonDir: "/r/.git"),
                       ["/r/.git", "/elsewhere/gitdir"])
    }

    /// FSEvents owns its reference to the relay through the context's
    /// retain/release pair: a running stream keeps the relay after the
    /// watcher's local is gone, and releasing the stream frees it.
    func testAStreamOwnsItsReferenceToTheRelay() throws {
        weak var running: GitRefsWatcher.Relay?
        var context: FSEventStreamContext
        do {
            let relay = GitRefsWatcher.Relay()
            running = relay
            context = GitRefsWatcher.context(for: relay)
            let retain = try XCTUnwrap(context.retain)
            XCTAssertEqual(retain(context.info), UnsafeRawPointer(context.info))
        }
        XCTAssertNotNil(running, "the stream's reference keeps the relay")
        try XCTUnwrap(context.release)(context.info)
        XCTAssertNil(running, "releasing the stream frees the relay")
    }

    /// The 0.29.0 crash: FSEvents refuses a stream (an empty path list makes
    /// it do so for real) after retaining and releasing the context itself.
    /// The relay stays its owner's, alive until the owner lets it go — the
    /// old hand release on this path freed it under its owner.
    func testARefusedStreamLeavesTheRelayToItsOwner() {
        weak var refused: GitRefsWatcher.Relay?
        do {
            let relay = GitRefsWatcher.Relay()
            refused = relay
            XCTAssertNil(GitRefsWatcher.makeStream(relay: relay, paths: [], latency: 0.1))
            XCTAssertNotNil(refused)
        }
        XCTAssertNil(refused)
    }

    private func watch(onChange: @escaping @MainActor (GitRefsChange) -> Void) -> GitRefsWatcher {
        let watcher = GitRefsWatcher(gitDir: gitDir.path, commonDir: gitDir.path, onChange: onChange)
        watchers.append(watcher)
        return watcher
    }

    /// One batch through the stream's own callback, the way fseventsd hands
    /// it over (a CFArray of paths, C arrays of flags and ids), with ids
    /// newer than the stream's start. The real fseventsd is not waited on: on
    /// a busy machine it delivers seconds late (#2389).
    private func deliver(_ watcher: GitRefsWatcher, _ names: [String], flag: Int = kFSEventStreamEventFlagItemRenamed) throws {
        try feed(watcher.relay, paths: names.map { realGitDir + "/" + $0 }, flag: flag,
                 ids: names.indices.map { watcher.startEventID + 1 + FSEventStreamEventId($0) })
    }

    private func feed(_ relay: GitRefsWatcher.Relay, paths: [String], flag: Int, ids: [FSEventStreamEventId]) throws {
        let flags = paths.map { _ in FSEventStreamEventFlags(flag) }
        let info = Unmanaged.passUnretained(relay).toOpaque()
        // The callback ignores the stream argument.
        let stream = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let cfPaths = paths as CFArray
        try withExtendedLifetime((relay, cfPaths)) {
            try flags.withUnsafeBufferPointer { flagBuffer in
                try ids.withUnsafeBufferPointer { idBuffer in
                    GitRefsWatcher.streamCallback(stream, info, paths.count,
                                                  Unmanaged.passUnretained(cfPaths).toOpaque(),
                                                  try XCTUnwrap(flagBuffer.baseAddress), try XCTUnwrap(idBuffer.baseAddress))
                }
            }
        }
    }

    /// FSEvents reports `/private/var/…`, not the temp dir's `/var/…`.
    /// (`resolvingSymlinksInPath` would strip `/private` again.)
    private var realGitDir: String {
        guard let resolved = realpath(gitDir.path, nil) else { return gitDir.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Per-file events (the header's paths are files), the first change at
    /// once, a rescan when `.git` is replaced, paths the callback can read.
    func testTheStreamFlags() {
        let flags = GitRefsWatcher.streamFlags
        for flag in [kFSEventStreamCreateFlagFileEvents, kFSEventStreamCreateFlagNoDefer,
                     kFSEventStreamCreateFlagWatchRoot, kFSEventStreamCreateFlagUseCFTypes] {
            XCTAssertNotEqual(flags & FSEventStreamCreateFlags(flag), 0, "flag \(flag)")
        }
    }

    func testTheWatcherStartsAStreamOnTheGitDir() {
        XCTAssertTrue(watch { _ in }.isWatching)
    }

    /// The way git updates a ref: `<ref>.lock` written, then renamed into
    /// place — one batch, one call.
    func testARefUpdateFiresOnce() throws {
        var changes: [GitRefsChange] = []
        let watcher = watch { changes.append($0) }
        try deliver(watcher, ["refs/heads/x.lock", "refs/heads/x"])
        XCTAssertEqual(changes, [GitRefsChange(mayMoveWorktrees: true)])
    }

    /// One call per notifying batch, however many relevant paths it holds;
    /// two batches call twice (`latency` is what coalesces them), and a
    /// batch of only the folder's own HEAD leaves the other worktrees alone.
    func testEachNotifyingBatchIsOneCall() throws {
        var changes: [GitRefsChange] = []
        let watcher = watch { changes.append($0) }
        try deliver(watcher, ["HEAD", "refs/heads/x", "packed-refs"])
        try deliver(watcher, ["refs/heads/x.lock"])
        try deliver(watcher, ["HEAD"])
        XCTAssertEqual(changes, [GitRefsChange(mayMoveWorktrees: true), GitRefsChange(mayMoveWorktrees: false)])
    }

    func testObjectWritesDoNotFire() throws {
        var fired = 0
        let watcher = watch { _ in fired += 1 }
        XCTAssertTrue(watcher.isWatching)
        try deliver(watcher, ["objects/ab/cd", "logs/HEAD"])
        XCTAssertEqual(fired, 0)
    }

    /// `.git` moved away and a new one put in its place (a re-clone, a
    /// worktree recreated): FSEvents says RootChanged, with event id 0.
    func testReplacingTheWatchedDirFires() throws {
        var fired = 0
        let watcher = watch { _ in fired += 1 }
        try feed(watcher.relay, paths: [realGitDir], flag: kFSEventStreamEventFlagRootChanged, ids: [0])
        XCTAssertEqual(fired, 1)
    }

    func testStopSilencesTheWatcher() throws {
        var fired = 0
        let watcher = watch { _ in fired += 1 }
        XCTAssertTrue(watcher.isWatching)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        try deliver(watcher, ["refs/heads/y"])
        XCTAssertEqual(fired, 0)
    }

    /// A batch FSEvents had in flight when the watcher went away finds the
    /// relay pointing at nothing.
    func testABatchAfterTheWatcherIsGoneIsDropped() throws {
        var fired = 0
        let relay: GitRefsWatcher.Relay
        do {
            let watcher = GitRefsWatcher(gitDir: gitDir.path, commonDir: gitDir.path) { _ in fired += 1 }
            relay = watcher.relay
        }
        XCTAssertNil(relay.watcher)
        try feed(relay, paths: [realGitDir + "/refs/heads/z"], flag: kFSEventStreamEventFlagItemRenamed, ids: [.max])
        XCTAssertEqual(fired, 0)
    }
}
