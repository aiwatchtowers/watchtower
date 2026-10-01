import Foundation

/// Watches one file for changes with a vnode `DispatchSource` (no polling,
/// no TCC-sensitive API beyond reading the file itself). Editors and Claude
/// Code often replace a file atomically (write a temp file, rename it over),
/// which deletes the watched inode — the watcher then re-opens the path, and
/// while the path is missing it retries every `retryInterval`.
@MainActor
final class DocumentFileWatcher {
    private let path: String
    private let retryInterval: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false

    init(url: URL, retryInterval: TimeInterval = 2, onChange: @escaping @MainActor () -> Void) {
        path = url.path
        self.retryInterval = retryInterval
        self.onChange = onChange
        arm()
    }

    func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }

    private func arm() {
        source?.cancel()
        source = nil
        guard !stopped else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                MainActor.assumeIsolated { self?.arm() }
            }
            return
        }
        let watched = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        watched.setEventHandler { [weak self, weak watched] in
            MainActor.assumeIsolated {
                guard let self, let watched else { return }
                let events = watched.data
                self.onChange()
                if events.contains(.delete) || events.contains(.rename) { self.arm() }
            }
        }
        watched.setCancelHandler { close(descriptor) }
        source = watched
        watched.resume()
    }
}
