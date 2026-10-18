import Foundation
import Observation
import WatchtowerCore

/// One file open in a Files tab. `diskText` is the last version read or
/// written; `text` is the editor's. Edits save themselves `autosaveDelay`
/// after the last one; `isDirty` = not on disk yet.
///
/// Never over somebody else's version (PROJ-03 as amended 2026-10-02): a
/// save re-reads the disk first, and anything but the version the edits
/// were made on — a newer text, a deletion, a file that no longer reads as
/// text — blocks it (`problem`) until the owner decides in the banner. The
/// page tags every edit with the disk revision it was typed on
/// (`externalRevision`), so an edit typed before a reload reached the page
/// becomes a conflict instead of landing on the new version.
@MainActor
@Observable
final class CodeFileBuffer {
    /// Bigger files are not opened: Monaco copes, the round trip through the
    /// JS bridge on every edit does not.
    nonisolated static let maxBytes = 5 * 1024 * 1024

    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// What stops the autosave until the owner decides.
    enum Problem: Equatable {
        /// The file changed on disk under unsaved edits.
        case conflict
        /// The file was deleted or moved away under unsaved edits.
        case deletedWhileEditing

        /// A read that failed for a reason that may pass (permissions, IO):
        /// worth a retry rather than an overwrite.
        var isTransient: Bool {
            if case .unreadable(.other) = self { return true }
            return false
        }
        /// The disk version can no longer be read as text (too big, binary,
        /// unreadable): nothing is written over what cannot be checked.
        case unreadable(ReadError)

        var message: String {
            switch self {
            case .conflict: "The file changed on disk while you were editing. Your edits are not saved."
            case .deletedWhileEditing: "The file was deleted or moved on disk while you were editing. Your edits are not saved."
            case let .unreadable(error): "The file on disk can no longer be read (\(error.message)). Your edits are not saved."
            }
        }
    }

    /// The page's key for this buffer's model: stable across a rename.
    let id = UUID().uuidString
    private(set) var url: URL
    private(set) var relPath: String
    private(set) var state: State = .loading
    private(set) var diskText = ""
    private(set) var text = ""
    private(set) var problem: Problem?
    /// The file is gone and the buffer has nothing unsaved.
    private(set) var deletedOnDisk = false
    /// Bumped when the editor must take `text` (a disk reload, Reload from
    /// disk, Keep mine): the page's edits carry the revision they were made on.
    private(set) var externalRevision = 0
    /// The revision at which the page must replace its text even over an
    /// edit it has not sent yet (Reload from disk).
    private(set) var forcedRevision = -1
    /// The revision at which the page keeps its text and only takes the new
    /// base, sending what it has not sent yet on it (Keep mine).
    private(set) var rebasedRevision = -1
    /// The last failed write or reload, as a full sentence for the banner.
    var saveError: String?
    /// Its root's worktree was removed (board #565): nothing is ever written
    /// again — a write would recreate the folder. The edits stay in memory
    /// for Copy or Discard.
    private(set) var writesLocked = false
    /// Told when a save finds the buffer's worktree folder gone (the
    /// buffer has locked itself): the center marks the root removed.
    @ObservationIgnored var onWorktreeMissing: (() -> Void)?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private let autosaveDelay: Duration
    /// The linked worktree the file lives in, nil for the workbench folder:
    /// every write first checks it still exists, so a worktree removed
    /// while nothing watched it is never recreated by a save.
    @ObservationIgnored private let worktreeFolder: URL?

    init(url: URL, relPath: String, autosaveDelay: Duration = .seconds(1), worktreeFolder: URL? = nil) {
        self.url = url
        self.relPath = relPath
        self.autosaveDelay = autosaveDelay
        self.worktreeFolder = worktreeFolder
    }

    var isDirty: Bool { state == .loaded && text != diskText }
    var conflict: Bool { problem == .conflict }

    /// Why a close could not save this buffer, nil when it can.
    var unsavedReason: String? {
        if writesLocked { return Self.lockedReason }
        if let problem { return problem.message }
        return saveError
    }

    func loadIfNeeded() {
        guard state != .loaded else { return }
        switch Self.read(url) {
        case let .success(content):
            diskText = content
            text = content
            state = .loaded
        case let .failure(error):
            state = .failed(error.message)
        }
    }

    /// The editor's text, typed on disk revision `base`. `now` (a flush)
    /// saves at once; `explicit` (Cmd+S) also writes back a file deleted
    /// while editing. Otherwise the save waits for a pause in typing.
    func edited(_ newText: String, base: Int, now: Bool = false, explicit: Bool = false) {
        guard state == .loaded else { return }
        text = newText
        if base < externalRevision {
            // Typed before a reload reached the page.
            if isDirty { problem = problem ?? .conflict }
            cancelAutosave()
            return
        }
        if now || explicit {
            saveNow(explicit: explicit)
        } else {
            scheduleAutosave()
        }
    }

    nonisolated static let lockedReason = "Its worktree was removed, so these edits are never written."

    /// The root's worktree is gone: autosave stops and every later save is
    /// refused, whatever the disk shows (also when the folder comes back).
    func lockWrites() {
        cancelAutosave()
        writesLocked = true
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard isDirty, problem == nil, !writesLocked else { return }
        let delay = autosaveDelay
        autosave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func cancelAutosave() {
        autosave?.cancel()
        autosave = nil
    }

    /// FSEvents saw the file change (our own saves included — those match
    /// the disk text and change nothing).
    func diskChanged() {
        guard state == .loaded else { return }
        switch Self.read(url) {
        case let .success(content):
            deletedOnDisk = false
            if case .unreadable = problem { problem = nil }
            if problem == .deletedWhileEditing { problem = .conflict }
            guard content != diskText else { return }
            if isDirty {
                problem = .conflict
                cancelAutosave()
            } else {
                diskText = content
                text = content
                externalRevision += 1
            }
        case .failure(.missing):
            if isDirty {
                problem = .deletedWhileEditing
                cancelAutosave()
            } else {
                deletedOnDisk = true
            }
        case let .failure(error):
            problem = .unreadable(error)
            cancelAutosave()
        }
    }

    /// Writes `text` when the disk still holds the version it was edited
    /// on; true when the disk now holds `text`. Atomic (a failed write never
    /// leaves a half file), keeping the file's permissions, through a
    /// symlink to the real file. `explicit` (Cmd+S, Keep mine) also writes
    /// back a file that was deleted.
    /// `overwrite` (Keep mine on an unreadable file) writes even though the
    /// disk version could not be read — the owner chose to replace it.
    @discardableResult
    func saveNow(explicit: Bool = false, overwrite: Bool = false) -> Bool {
        cancelAutosave()
        guard state == .loaded else { return true }
        guard !writesLocked else { return !isDirty }
        let gone = deletedOnDisk || problem == .deletedWhileEditing
        guard isDirty || (gone && explicit) else { return true }
        guard worktreeStillThere() else { return !isDirty }
        guard problemAllowsWrite(explicit: explicit, overwrite: overwrite),
              diskAllowsWrite(explicit: explicit, overwrite: overwrite) else { return false }
        do {
            try Self.writeText(text, to: url)
            diskText = text
            problem = nil
            deletedOnDisk = false
            saveError = nil
            return true
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// false — and the buffer locked for good — when its worktree folder
    /// is gone.
    private func worktreeStillThere() -> Bool {
        guard let worktreeFolder, !CodeRootPolicy.directoryExists(worktreeFolder) else { return true }
        lockWrites()
        onWorktreeMissing?()
        return false
    }

    private func problemAllowsWrite(explicit: Bool, overwrite: Bool) -> Bool {
        switch problem {
        case .conflict?: false
        case .unreadable?: overwrite
        case .deletedWhileEditing?: explicit
        case nil: true
        }
    }

    /// The disk still holds the version the edits were made on (or the
    /// owner chose to write anyway); otherwise `problem` says why not.
    private func diskAllowsWrite(explicit: Bool, overwrite: Bool) -> Bool {
        switch Self.read(url) {
        case let .success(onDisk) where onDisk != diskText:
            problem = .conflict
            return false
        case .success:
            return true
        case .failure(.missing):
            if !explicit { problem = .deletedWhileEditing }
            return explicit
        case let .failure(error):
            if !overwrite { problem = .unreadable(error) }
            return overwrite
        }
    }

    /// Banner, for a read that failed for a passing reason: read again.
    func retryRead() {
        diskChanged()
    }

    /// Banner: drop the unsaved edits, take the disk version.
    func reloadFromDisk() {
        switch Self.read(url) {
        case let .success(content):
            cancelAutosave()
            diskText = content
            text = content
            problem = nil
            deletedOnDisk = false
            saveError = nil
            externalRevision += 1
            forcedRevision = externalRevision
        case let .failure(error):
            saveError = "Could not reload: \(error.message)"
        }
    }

    /// Banner: keep the edits and write them over whatever is on disk (or
    /// back, if the file was deleted). The page's current text becomes the
    /// new base.
    func keepMine() {
        let overwrite: Bool
        if case .unreadable? = problem { overwrite = true } else { overwrite = false }
        if case let .success(content) = Self.read(url) { diskText = content }
        problem = nil
        externalRevision += 1
        rebasedRevision = externalRevision
        saveNow(explicit: true, overwrite: overwrite)
    }

    /// The file was renamed or moved from the tree.
    func moved(to newURL: URL, relPath newPath: String) {
        url = newURL
        relPath = newPath
    }

    /// Writes atomically to the real file behind any symlink, keeping its
    /// POSIX permissions (an executable script stays executable).
    nonisolated static func writeText(_ text: String, to url: URL) throws {
        let target = URL(fileURLWithPath: FolderWatcher.realPath(url.path))
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try Data(text.utf8).write(to: target, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    enum ReadError: Error, Equatable {
        case missing
        case tooBig
        case notText
        case other(String)

        var message: String {
            switch self {
            case .missing: "The file no longer exists."
            case .tooBig: "The file is larger than 5 MB — open it in an external editor."
            case .notText: "Not a UTF-8 text file."
            case let .other(message): message
            }
        }
    }

    nonisolated static func read(_ url: URL) -> Result<String, ReadError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxBytes else { return .failure(.tooBig) }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { return .failure(.notText) }
            return .success(text)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }
}
