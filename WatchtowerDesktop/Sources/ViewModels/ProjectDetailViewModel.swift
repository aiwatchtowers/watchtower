import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The chat project page (spec §6.1): name, instructions (debounced save),
/// pinned sources, files, and the project's chats. The page is short-lived
/// and its only async state is a pending instructions save, which `flush()`
/// writes on disappear — so the VM can be view-local.
///
/// Edits reach the assistant on each chat's next turn: the project block and
/// first-turn files are read by `ai session` at spawn, so every write that
/// changes them drops the chats' stored sessions (`ChatProjectQueries`) and
/// reports `onPromptChanged`, whose owner retires the warm processes.
@MainActor
@Observable
final class ProjectDetailViewModel {
    let projectID: Int64
    private(set) var project: ChatProject?
    private(set) var sources: [ChatProjectSource] = []
    private(set) var files: [ChatAttachment] = []
    private(set) var chats: [ChatConversation] = []
    private(set) var errorMessage: String?
    private(set) var pendingSave: Task<Void, Never>?
    var nameDraft = ""
    private(set) var instructionsDraft = ""
    /// The drafts hold the stored row. Until a `load()` succeeds they are
    /// empty placeholders, so editing is off: a save would overwrite the
    /// stored instructions with whatever was typed over the blank.
    private(set) var draftsLoaded = false
    /// The instructions as last read or written: a save of the same text is
    /// skipped (it would retire every chat's session for nothing).
    private var savedInstructions = ""

    private let dbPool: DatabasePool
    private let debounce: Duration
    private let importFile: (URL, Int64) throws -> ChatAttachment
    /// `chat_files` root: a deleted project's (now empty) directory goes too.
    private let attachmentsRoot: URL?
    /// After a committed write that changes the project's prompt.
    private let onPromptChanged: (Int64) -> Void

    init(
        projectID: Int64,
        dbPool: DatabasePool,
        debounce: Duration = .milliseconds(500),
        attachmentsRoot: URL? = nil,
        importFile: @escaping (URL, Int64) throws -> ChatAttachment,
        onPromptChanged: @escaping (Int64) -> Void = { _ in }
    ) {
        self.projectID = projectID
        self.dbPool = dbPool
        self.debounce = debounce
        self.importFile = importFile
        self.attachmentsRoot = attachmentsRoot
        self.onPromptChanged = onPromptChanged
    }

    /// Reads everything and resets both drafts from the stored row.
    func load() {
        guard refresh(), let project else { return }
        nameDraft = project.name
        instructionsDraft = project.instructions
        savedInstructions = project.instructions
        draftsLoaded = true
        errorMessage = nil
    }

    func instructionsEdited(_ text: String) {
        guard draftsLoaded else { return }
        instructionsDraft = text
        pendingSave?.cancel()
        let delay = debounce
        pendingSave = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            self?.saveInstructions()
        }
    }

    /// Writes the instructions draft now if it differs from what is stored
    /// (the page is going away, or a new chat is about to read them) — also
    /// after an earlier save failed. False when the write fails,
    /// `errorMessage` then says why.
    @discardableResult
    func flush() async -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        return saveInstructions()
    }

    func rename(_ name: String) {
        write { db, id in try ChatProjectQueries.rename(db, id: id, name: name) }
        nameDraft = project?.name ?? nameDraft
    }

    func addSource(_ hit: ChatEntityHit) {
        guard let kind = ChatProjectSource.Kind(entity: hit.kind) else { return }
        var added = false
        write { db, id in
            added = try ChatProjectQueries.addSource(db, projectID: id, kind: kind, ref: hit.ref, label: hit.label)
        }
        if added { onPromptChanged(projectID) }
    }

    func removeSource(_ source: ChatProjectSource) {
        if write({ db, _ in try ChatProjectQueries.removeSource(db, id: source.id) }) {
            onPromptChanged(projectID)
        }
    }

    func addFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                _ = try importFile(url, projectID)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if failures.count < urls.count { onPromptChanged(projectID) }
        guard refresh() else { return }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func removeFile(_ file: ChatAttachment) {
        do {
            let path = try dbPool.write { try ChatProjectQueries.removeFile($0, id: file.id) }
            onPromptChanged(projectID)
            if let path { Self.removeFromDisk([path]) }
            if refresh() { errorMessage = nil }
        } catch {
            errorMessage = "Could not remove \(file.name): \(error.localizedDescription)"
        }
    }

    /// Deletes the project (chats survive, detached; files go post-commit).
    /// Returns false on a write failure, with `errorMessage` set.
    func deleteProject() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let id = projectID
            let paths = try dbPool.write { try ChatProjectQueries.delete($0, id: id) }
            Self.removeFromDisk(paths)
            if let attachmentsRoot {
                ChatAttachmentStore.removeFiles(for: .project(id), rootDir: attachmentsRoot)
            }
            // Nothing is left to save into: the page's closing flush must not
            // write an unsaved draft to the deleted row.
            draftsLoaded = false
            return true
        } catch {
            errorMessage = "Could not delete the project: \(error.localizedDescription)"
            return false
        }
    }

    /// Re-reads the row and lists without touching the drafts, so a rename or
    /// source change never clobbers instructions the owner is still typing.
    @discardableResult
    private func refresh() -> Bool {
        do {
            let id = projectID
            let snapshot = try dbPool.read { db in
                (try ChatProjectQueries.fetchByID(db, id: id),
                 try ChatProjectQueries.sources(db, projectID: id),
                 try ChatProjectQueries.files(db, projectID: id),
                 try ChatProjectQueries.conversations(db, projectID: id))
            }
            project = snapshot.0
            sources = snapshot.1
            files = snapshot.2
            chats = snapshot.3
            return true
        } catch {
            errorMessage = "Could not load the project: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func saveInstructions() -> Bool {
        guard draftsLoaded else { return true }
        let text = instructionsDraft
        guard text != savedInstructions else {
            pendingSave = nil
            return true
        }
        let id = projectID
        do {
            try dbPool.write { try ChatProjectQueries.updateInstructions($0, id: id, instructions: text) }
            pendingSave = nil
            savedInstructions = text
            onPromptChanged(id)
            return true
        } catch {
            // flush() runs as the page goes away, where the banner is gone
            // too: keep a trace as well.
            NSLog("ProjectDetailViewModel: could not save instructions: %@", error.localizedDescription)
            errorMessage = "Could not save instructions: \(error.localizedDescription)"
            return false
        }
    }

    /// Returns whether the write committed.
    @discardableResult
    private func write(_ body: (Database, Int64) throws -> Void) -> Bool {
        let id = projectID
        do {
            try dbPool.write { try body($0, id) }
            if refresh() { errorMessage = nil }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Best effort, post-commit (spec §7.1): a file already gone is success.
    private static func removeFromDisk(_ paths: [String]) {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                NSLog("ProjectDetailViewModel: could not remove %@: %@", path, error.localizedDescription)
            }
        }
    }
}

extension ProjectDetailViewModel {
    enum ImportError: LocalizedError {
        case noWorkspace
        var errorDescription: String? { "Attachments need an active workspace" }
    }

    /// The production importer: the shared attachment store (validation,
    /// 0600 copy under `chat_files/projects/<id>/`). Without an active
    /// workspace every import fails with a visible reason.
    static func storeImporter(dbPool: DatabasePool, rootDir: URL?) -> (URL, Int64) throws -> ChatAttachment {
        guard let rootDir else { return { _, _ in throw ImportError.noWorkspace } }
        let store = ChatAttachmentStore(db: dbPool, rootDir: rootDir)
        return { url, projectID in try store.importFile(url: url, projectID: projectID) }
    }
}
