import CoreServices
import Foundation

/// Watches a workbench folder's git dir and common dir with FSEvents and
/// calls `onChange` when something the header shows may have moved: HEAD,
/// the index, a local or remote-tracking ref, packed-refs, or another
/// worktree's HEAD (#233). Object writes, reflogs and `*.lock` files are
/// ignored, so a commit in progress does not flood the CLI. It never runs
/// git — the owner of the callback re-reads `workbench git status`.
/// One callback per FSEvents batch (`latency` coalesces them; NoDefer
/// delivers the first one at once). `stop()` silences it for good.
@MainActor
final class GitRefsWatcher {
    /// FSEvents holds this, not the watcher, so a callback after the watcher
    /// is gone finds nil instead of a freed object.
    private final class Relay {
        weak var watcher: GitRefsWatcher?
    }

    /// Real paths (FSEvents reports `/private/var/…`, not `/var/…`).
    private let gitDir: String
    private let commonDir: String
    private let onChange: @MainActor () -> Void
    /// Touched only on the main actor and in deinit, after the last use.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    /// The journal's last event id when the stream started: fseventsd can
    /// still hand over a change made just before, which is not news.
    private var startEventID: FSEventStreamEventId = 0

    init(gitDir: String, commonDir: String, latency: TimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        self.gitDir = Self.realPath(gitDir)
        self.commonDir = Self.realPath(commonDir.isEmpty ? gitDir : commonDir)
        self.onChange = onChange
        start(latency: latency)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
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

    private func start(latency: TimeInterval) {
        let relay = Relay()
        relay.watcher = self
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(relay).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: `paths` is a CFArray of CFString.
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            let idList = Array(UnsafeBufferPointer(start: ids, count: count))
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { relay.watcher?.handle(paths: list, flags: flagList, ids: idList) }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        let watched = Self.watchedPaths(gitDir: gitDir, commonDir: commonDir)
        startEventID = FSEventsGetCurrentEventId()
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else {
            // FSEvents refused the stream; the caller's timer and
            // app-activation reads still refresh the header.
            print("[GitRefsWatcher] could not watch \(watched.joined(separator: ", "))")
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        guard stream != nil else { return }
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs)
        let relevant = zip(paths, zip(flags, ids)).contains { path, event in
            let (flag, id) = event
            guard id > startEventID else { return false }
            return flag & rescan != 0 || Self.isRelevant(path: path, gitDir: gitDir, commonDir: commonDir)
        }
        if relevant { onChange() }
    }

    nonisolated private static func realPath(_ path: String) -> String {
        guard !path.isEmpty, let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
