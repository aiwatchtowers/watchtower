import ChatWire
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The chat project page (spec §6.1): name, instructions (debounced save),
/// pinned sources, files, and the project's chats. The page is short-lived
/// and its only async state is a pending instructions save, which `flush()`
/// writes on disappear — so the VM can be view-local.
///
/// It reads its rows itself (D19); every write is the engine's
/// (`project_manage`), which also retires the project's chats' warm sessions
/// so the next turn reads the new prompt.
@MainActor
@Observable
final class ProjectDetailViewModel {
    let projectID: Int64
    private(set) var project: ChatProject?
    private(set) var sources: [WatchtowerCore.ChatProjectSource] = []
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
    /// The Instructions card's editor text while it is open (nil = the
    /// preview). Nothing is written until Save; Cancel drops it.
    var instructionsEditor: String?

    /// The Knowledge card's list: files, then pinned sources.
    var knowledge: [ProjectKnowledgeItem] { ProjectKnowledgeItem.merged(files: files, sources: sources) }

    private let dbPool: DatabasePool
    private let client: any ChatClient
    /// Every write of this view model, in order.
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending delete.
    private let pendingWrites = PendingWrites()
    private let debounce: Duration

    init(projectID: Int64, dbPool: DatabasePool, client: any ChatClient, debounce: Duration = .milliseconds(500)) {
        self.projectID = projectID
        self.dbPool = dbPool
        self.client = client
        self.debounce = debounce
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

    /// Re-reads the row and lists, drafts untouched (a chat deleted from
    /// the panel's Undo bar left the project).
    func reloadLists() {
        if refresh() { errorMessage = nil }
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
            await self?.saveInstructions()
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
        return await saveInstructions()
    }

    func beginInstructionsEdit() {
        guard draftsLoaded else { return }
        instructionsEditor = instructionsDraft
    }

    /// Cancel: the stored text stays, also over a draft a failed Save left
    /// behind (the page's closing flush would write it otherwise).
    func cancelInstructionsEdit() {
        instructionsEditor = nil
        pendingSave?.cancel()
        pendingSave = nil
        instructionsDraft = savedInstructions
    }

    /// Save: the editor's text is written now. A failed write keeps the
    /// editor open with its text, `errorMessage` says why.
    @discardableResult
    func commitInstructionsEdit() async -> Bool {
        guard let text = instructionsEditor, draftsLoaded else { return false }
        instructionsEdited(text)
        guard await flush() else { return false }
        // Text typed while the save waited stays in the editor.
        if instructionsEditor == text { instructionsEditor = nil }
        return true
    }

    /// The remove button of a Knowledge row.
    func removeKnowledge(_ id: ProjectKnowledgeItem.Key) async {
        switch id {
        case .file(let fileID):
            if let file = files.first(where: { $0.id == fileID }) { await removeFile(file) }
        case .source(let sourceID):
            if let source = sources.first(where: { $0.id == sourceID }) { await removeSource(source) }
        }
    }

    func rename(_ name: String) async {
        await write(ChatProjectRequest(op: .update, projectID: projectID, name: name))
        // Text typed while the rename waited stays.
        if nameDraft == name { nameDraft = project?.name ?? nameDraft }
    }

    /// A picked entity pinned as a source (a Jira issue is not pinned: its project is).
    func addSource(_ hit: ChatEntityHit) async {
        guard let kind = Self.sourceKind(hit.kind) else { return }
        await write(ChatProjectRequest(op: .sourceAdd, projectID: projectID,
                                       sources: [ChatWire.ChatProjectSource(kind: kind, ref: hit.id, label: hit.label)]))
    }

    func removeSource(_ source: WatchtowerCore.ChatProjectSource) async {
        await write(ChatProjectRequest(op: .sourceRemove, sourceID: source.id))
    }

    /// The project source kind of a picker hit (`chat_project_sources.kind`); nil for an issue.
    static func sourceKind(_ entity: String) -> String? {
        switch entity {
        case "person": "person"
        case "channel": "slack_channel"
        case "jira_project": "jira_project"
        case "confluence_space": "confluence_space"
        case "target": "target"
        case "track": "track"
        default: nil
        }
    }

    /// Each file is copied by the engine (`file_add`, the app passes the path it holds); the list shows them once
    /// stored.
    func addFiles(_ urls: [URL]) async {
        var failures: [String] = []
        for url in urls {
            if let failure = await apply(ChatProjectRequest(op: .fileAdd, projectID: projectID, path: url.path)) {
                failures.append("\(url.lastPathComponent): \(failure)")
            }
        }
        guard refresh() else { return }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func removeFile(_ file: ChatAttachment) async {
        if let failure = await apply(ChatProjectRequest(op: .fileRemove, fileID: file.id)) {
            errorMessage = "Could not remove \(file.name): \(failure)"
        } else if refresh() {
            errorMessage = nil
        }
    }

    /// Deletes the project (chats survive, detached; files go post-commit).
    /// Returns false on a write failure, with `errorMessage` set.
    /// A second press while the delete waits does nothing (false).
    func deleteProject() async -> Bool {
        await pendingWrites.run("delete") { await deleteNow() } ?? false
    }

    private func deleteNow() async -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        // The delete is in the chain: a save asked for before it lands first.
        if let failure = await apply(ChatProjectRequest(op: .delete, projectID: projectID)) {
            errorMessage = "Could not delete the project: \(failure)"
            return false
        }
        // Nothing is left to save into: the page's closing flush must not
        // write an unsaved draft to the deleted row.
        draftsLoaded = false
        return true
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

    /// Saves run in the view model's chain (board #670): each reads the draft
    /// when its turn comes, so the newest text lands last and a save that
    /// finds it already stored writes nothing. The chain runs the write in its
    /// own task, so a debounce cancelled meanwhile never cancels a write under
    /// way.
    @discardableResult
    private func saveInstructions() async -> Bool {
        await writes.run { await self.writeInstructions() }
    }

    private func writeInstructions() async -> Bool {
        guard draftsLoaded else { return true }
        let text = instructionsDraft
        guard text != savedInstructions else {
            pendingSave = nil
            return true
        }
        if let failure = await send(ChatProjectRequest(op: .update, projectID: projectID, instructions: text)) {
            // flush() runs as the page goes away, where the banner is gone too: keep a trace as well.
            NSLog("ProjectDetailViewModel: could not save instructions (%@)", failure)
            errorMessage = "Could not save instructions: \(failure)"
            return false
        }
        pendingSave = nil
        savedInstructions = text
        return true
    }

    /// One project write, then the page re-reads; false (and `errorMessage`) when the engine did not apply it.
    @discardableResult
    private func write(_ request: ChatProjectRequest) async -> Bool {
        if let failure = await apply(request) {
            errorMessage = failure
            return false
        }
        if refresh() { errorMessage = nil }
        return true
    }

    /// One project write in this view model's chain: nil once applied, else why not.
    private func apply(_ request: ChatProjectRequest) async -> String? {
        await writes.run { await self.send(request) }
    }

    /// The engine's answer to one project write (already in the chain): nil once applied, else why not.
    private func send(_ request: ChatProjectRequest) async -> String? {
        do {
            switch try await client.send(.project(request)) {
            case .applied: return nil
            case let .refused(_, message): return message.isEmpty ? "The change was refused." : message
            }
        } catch {
            return "Couldn't reach Watchtower: \(error.localizedDescription)"
        }
    }
}
