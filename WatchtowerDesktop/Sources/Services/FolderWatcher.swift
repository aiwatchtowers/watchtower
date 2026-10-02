import CoreServices
import Foundation

/// An FSEvents stream over one workbench folder for the code viewer: the
/// changed paths relative to it (debounced by the stream's latency), whether
/// git's index, HEAD or refs moved (a commit, a checkout), and whether the
/// stream lost events (then everything must be re-read). Paths inside `.git`
/// and inside the folders the FILES tree hides (build output, dependencies)
/// are dropped, so a build does not keep the tree and git busy.
final class FolderWatcher {
    struct Batch: Equatable {
        var paths: Set<String> = []
        var gitChanged = false
        /// FSEvents dropped or coalesced events: rescan everything.
        var mustRescan = false

        var isEmpty: Bool { paths.isEmpty && !gitChanged && !mustRescan }
    }

    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let hidden: Set<String>
    private let onChange: @MainActor (Batch) -> Void

    /// nil when the stream cannot be created or started — the caller says so
    /// (the FILES header), it does not pretend the view is live.
    init?(root: URL, hidden: Set<String>, onChange: @escaping @MainActor (Batch) -> Void) {
        rootPath = Self.realPath(root.path)
        self.hidden = hidden
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, count, paths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let array = unsafeBitCast(paths, to: NSArray.self)
                let events = (0 ..< count).compactMap { index -> (String, FSEventStreamEventFlags)? in
                    guard let path = array[index] as? String else { return nil }
                    return (path, eventFlags[index])
                }
                watcher.deliver(events)
            },
            &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return nil }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func deliver(_ events: [(String, FSEventStreamEventFlags)]) {
        let batch = Self.classify(events, rootPath: rootPath, hidden: hidden)
        guard !batch.isEmpty else { return }
        MainActor.assumeIsolated { onChange(batch) }
    }

    /// Pure, for tests: FSEvents' absolute paths and flags → one batch.
    static func classify(_ events: [(String, FSEventStreamEventFlags)], rootPath: String, hidden: Set<String>) -> Batch {
        let lost = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        let prefix = rootPath + "/"
        var batch = Batch()
        for (path, flags) in events {
            if flags & lost != 0 { batch.mustRescan = true }
            guard path.hasPrefix(prefix) else {
                if path == rootPath { batch.paths.insert("") }
                continue
            }
            let relative = String(path.dropFirst(prefix.count))
            let parts = relative.split(separator: "/")
            if parts.first == ".git" {
                let inner = parts.dropFirst().joined(separator: "/")
                if inner == "index" || inner == "HEAD" || inner.hasPrefix("refs/") { batch.gitChanged = true }
                continue
            }
            if parts.contains(where: { $0 == ".git" || hidden.contains(String($0)) }) { continue }
            batch.paths.insert(relative)
        }
        return batch
    }

    /// FSEvents reports real paths (/private/var/…); `resolvingSymlinksInPath`
    /// strips /private again, so realpath(3) it is.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
