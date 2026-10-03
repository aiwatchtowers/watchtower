import Darwin
import Foundation

/// Watches the owner's code-index rules file (`code-languages.yaml`, spec
/// §6.5) for being created, edited, replaced or removed, with two vnode
/// `DispatchSource`s and no polling: one on its folder (an entry added,
/// removed or renamed — an atomic save renames a temp file over it) and
/// one on the file itself (written in place). The folder is the app's
/// Application Support folder, where the database's writes wake the
/// folder source too: a change is reported only when the file's identity,
/// size or modification time moved.
@MainActor
final class CodeRulesFileWatcher {
    /// What tells one state of the file from another; nil = no file.
    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec

        static func == (a: Self, b: Self) -> Bool {
            (a.device, a.inode, a.size, a.modified.tv_sec, a.modified.tv_nsec)
                == (b.device, b.inode, b.size, b.modified.tv_sec, b.modified.tv_nsec)
        }

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }

        static func of(_ path: String) -> Self? {
            var info = stat()
            return stat(path, &info) == 0 ? Self(info) : nil
        }
    }

    private let path: String
    private let onChange: @MainActor () -> Void
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    /// The file the file source is open on (nil = none: the file is missing).
    private var watchedFile: Fingerprint?
    private var fingerprint: Fingerprint?

    /// nil when the file's folder cannot be opened (it does not exist yet):
    /// the caller tries again later.
    init?(file: URL, onChange: @escaping @MainActor () -> Void) {
        path = file.path
        self.onChange = onChange
        let folder = file.deletingLastPathComponent().path
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { close(descriptor) }
        folderSource = source
        fingerprint = Fingerprint.of(path)
        armFileSource()
        source.resume()
    }

    func stop() {
        folderSource?.cancel()
        folderSource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// Something happened in the folder or to the file.
    private func check() {
        guard folderSource != nil else { return }
        let now = Fingerprint.of(path)
        // Created, replaced or removed: the file source follows the path.
        if now?.device != watchedFile?.device || now?.inode != watchedFile?.inode { armFileSource() }
        guard now != fingerprint else { return }
        fingerprint = now
        onChange()
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        watchedFile = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            return
        }
        watchedFile = Fingerprint(info)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.resume()
    }
}
