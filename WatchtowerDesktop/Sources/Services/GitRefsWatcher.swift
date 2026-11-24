import CoreServices
import Foundation
import os
import WatchtowerCore

/// What the workbench view model holds per watched folder; a seam for tests.
@MainActor
protocol GitRefsWatching: AnyObject {
    func stop()
}

/// What one notifying FSEvents batch may have moved.
struct GitRefsChange: Equatable, Sendable {
    /// Something beyond the watched folder's own HEAD and index: a ref,
    /// packed-refs, another worktree's HEAD, or a rescan — the branch of a
    /// linked worktree may have moved (board #565). A batch of only the
    /// folder's HEAD/index leaves the other worktrees as they were.
    let mayMoveWorktrees: Bool
}

/// Watches a workbench folder's git dir and common dir with FSEvents and
/// calls `onChange` when something the header shows may have moved: HEAD,
/// the index, a local or remote-tracking ref, packed-refs, or another
/// worktree's HEAD (#233). Object writes, reflogs and `*.lock` files are
/// ignored, so a commit in progress does not flood the CLI. It never runs
/// git — the owner of the callback re-reads `workbench git status`.
/// One callback per FSEvents batch, saying whether it may concern another
/// worktree (`GitRefsChange`) (`latency` coalesces them; NoDefer
/// delivers the first one at once). `stop()` silences it for good.
@MainActor
final class GitRefsWatcher: GitRefsWatching {
    /// What FSEvents holds instead of the watcher: it points back weakly,
    /// so a callback after the watcher is gone finds nil instead of a freed
    /// object.
    final class Relay {
        weak var watcher: GitRefsWatcher?

        /// One FSEvents batch, as the stream's callback hands it over. Tests
        /// feed batches here: the real fseventsd can take seconds to deliver
        /// on a busy machine (#2389).
        @MainActor
        func deliver(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
            watcher?.handle(paths: paths, flags: flags, ids: ids)
        }
    }

    private static let log = Logger(subsystem: Constants.bundleID, category: "git-refs-watcher")

    /// Real paths (FSEvents reports `/private/var/…`, not `/var/…`).
    private let gitDir: String
    private let commonDir: String
    private let onChange: @MainActor (GitRefsChange) -> Void
    /// Touched only on the main actor and in deinit, after the last use.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    /// The journal's last event id when the stream started: fseventsd can
    /// still hand over a change made just before, which is not news.
    private(set) var startEventID: FSEventStreamEventId = 0
    /// What the stream's callback delivers to; FSEvents holds it too.
    let relay = Relay()

    /// Whether FSEvents accepted and started the stream, and `stop()` has
    /// not been called.
    var isWatching: Bool { stream != nil }

    init(gitDir: String, commonDir: String, latency: TimeInterval = 0.5, onChange: @escaping @MainActor (GitRefsChange) -> Void) {
        self.gitDir = Self.realPath(gitDir)
        self.commonDir = Self.realPath(commonDir.isEmpty ? gitDir : commonDir)
        self.onChange = onChange
        start(latency: latency)
    }

    deinit {
        if let stream { Self.tearDown(stream) }
    }

    func stop() {
        guard let stream else { return }
        Self.tearDown(stream)
        self.stream = nil
    }

    /// Releasing the stream releases the relay it holds (the context's
    /// `release`).
    nonisolated private static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// The directories one stream watches: the common dir, plus the git dir
    /// unless it is the same directory or inside it (a linked worktree's
    /// `.git/worktrees/<name>`).
    nonisolated static func watchedPaths(gitDir: String, commonDir: String) -> [String] {
        if gitDir == commonDir || gitDir.hasPrefix(commonDir + "/") { return [commonDir] }
        return [commonDir, gitDir]
    }

    /// Whether a changed path is one the header reads. Pure, so the table is
    /// tested without FSEvents.
    nonisolated static func isRelevant(path: String, gitDir: String, commonDir: String) -> Bool {
        [gitDir, commonDir].contains { root in
            guard !root.isEmpty, path.hasPrefix(root + "/") else { return false }
            return isRelevant(relative: String(path.dropFirst(root.count + 1)))
        }
    }

    /// Whether one FSEvents batch calls `onChange`. A rescan (the root was
    /// renamed, deleted or recreated, or events were dropped) always does,
    /// checked before the id filter: RootChanged arrives with event id 0.
    /// Otherwise only an event newer than the stream's start, on a path the
    /// header reads. Pure, so it is tested without FSEvents.
    nonisolated static func shouldNotify(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        ids: [FSEventStreamEventId],
        startEventID: FSEventStreamEventId,
        gitDir: String,
        commonDir: String
    ) -> Bool {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs)
        return zip(paths, zip(flags, ids)).contains { path, event in
            let (flag, id) = event
            if flag & rescan != 0 { return true }
            return id > startEventID && isRelevant(path: path, gitDir: gitDir, commonDir: commonDir)
        }
    }

    /// Whether a notifying batch may have moved a linked worktree's branch:
    /// a rescan, or a new relevant event other than the watched folder's own
    /// HEAD or index (relative to `gitDir`). Pure, tested without FSEvents.
    nonisolated static func mayMoveWorktrees(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        ids: [FSEventStreamEventId],
        startEventID: FSEventStreamEventId,
        gitDir: String,
        commonDir: String
    ) -> Bool {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs)
        let ownFiles = [gitDir + "/HEAD", gitDir + "/index"]
        return zip(paths, zip(flags, ids)).contains { path, event in
            let (flag, id) = event
            if flag & rescan != 0 { return true }
            guard id > startEventID, !ownFiles.contains(path) else { return false }
            return isRelevant(path: path, gitDir: gitDir, commonDir: commonDir)
        }
    }

    nonisolated private static func isRelevant(relative: String) -> Bool {
        if relative.hasSuffix(".lock") { return false }
        let parts = relative.split(separator: "/")
        switch parts.first {
        case "HEAD", "index", "packed-refs":
            return parts.count == 1
        case "refs":
            return parts.count >= 3 && (parts[1] == "heads" || parts[1] == "remotes")
        case "worktrees":
            return parts.count == 3 && parts[2] == "HEAD"
        default:
            return false
        }
    }

    /// The stream's context for `relay`. FSEvents owns its reference through
    /// the retain/release pair, and balances it itself: a refused create
    /// retains and then releases the context before returning NULL (seen on
    /// macOS 27 with an empty path list), so the watcher never releases the
    /// relay by hand. The 0.29.0 crash in `start` was a hand-rolled
    /// `passRetained` with `retain: nil`, released once more on that path.
    nonisolated static func context(for relay: Relay) -> FSEventStreamContext {
        FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Relay>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
    }

    /// A stream relaying to `relay`, or nil when FSEvents refuses it (FSEvents
    /// has then dropped its reference again). `relay` is kept alive across
    /// the create: the context hands it over unretained.
    nonisolated static func makeStream(
        relay: Relay, paths: [String], latency: TimeInterval
    ) -> FSEventStreamRef? {
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: `paths` is a CFArray of CFString.
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            let idList = Array(UnsafeBufferPointer(start: ids, count: count))
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { relay.deliver(paths: list, flags: flagList, ids: idList) }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        return withExtendedLifetime(relay) {
            var context = context(for: relay)
            return FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
            )
        }
    }

    private func start(latency: TimeInterval) {
        relay.watcher = self
        let watched = Self.watchedPaths(gitDir: gitDir, commonDir: commonDir)
        startEventID = FSEventsGetCurrentEventId()
        guard let created = Self.makeStream(relay: relay, paths: watched, latency: latency) else {
            // The caller's timer and app-activation reads still refresh the
            // header.
            Self.log.error("could not watch \(watched.joined(separator: ", "), privacy: .private)")
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            // Never started, so nothing to stop; releasing it releases
            // FSEvents' reference to the relay.
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            Self.log.error("could not start watching \(watched.joined(separator: ", "), privacy: .private)")
            return
        }
        stream = created
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        guard stream != nil else { return }
        guard Self.shouldNotify(paths: paths, flags: flags, ids: ids, startEventID: startEventID,
                                gitDir: gitDir, commonDir: commonDir) else { return }
        onChange(GitRefsChange(mayMoveWorktrees: Self.mayMoveWorktrees(
            paths: paths, flags: flags, ids: ids, startEventID: startEventID, gitDir: gitDir, commonDir: commonDir
        )))
    }

    nonisolated private static func realPath(_ path: String) -> String {
        guard !path.isEmpty, let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
