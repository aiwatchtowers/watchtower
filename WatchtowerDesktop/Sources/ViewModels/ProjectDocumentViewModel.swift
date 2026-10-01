import Foundation
import GRDB
import Observation
import WatchtowerCore

/// One open project document: its rendered text, its comment threads and
/// their anchors (spec §6.3). Owned by `ProjectsViewModel`, so it outlives
/// pane switches. Reads and watches the file; never writes it (PROJ-03).
@MainActor
@Observable
final class ProjectDocumentViewModel {
    let project: Project
    private(set) var document: ProjectDocument
    private(set) var rendered: RenderedDocument?
    private(set) var threads: [ProjectCommentThread] = []
    /// Root comment id → its located range in `rendered.text`.
    private(set) var anchoredRanges: [Int64: NSRange] = [:]
    /// Draft id → its located range in `rendered.text`; a draft whose passage
    /// is gone has none and is not sent until the owner deletes or re-makes it.
    private(set) var draftRanges: [UUID: NSRange] = [:]
    private(set) var loadError: String?
    var errorMessage: String?
    /// The reload a file change scheduled (exposed for tests).
    private(set) var pendingReload: Task<Void, Never>?
    /// Bumped on every successful `load()`; part of the text view's content
    /// id, so a composer opened on an older render refuses to save
    /// (`CommentableDocumentText`) — its selection points into text that is gone.
    private(set) var renderVersion = 0

    var onOwnerWrite: ((ProjectSubject) -> Void)?

    private let dbPool: DatabasePool
    private let draftStore: ProjectCommentDrafts
    private let readFile: (URL) throws -> String
    private let reloadDelay: Duration
    private var watcher: DocumentFileWatcher?

    init(
        dbPool: DatabasePool,
        project: Project,
        document: ProjectDocument,
        drafts: ProjectCommentDrafts = ProjectCommentDrafts(),
        reloadDelay: Duration = .milliseconds(500),
        readFile: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) {
        self.dbPool = dbPool
        self.project = project
        self.document = document
        self.draftStore = drafts
        self.reloadDelay = reloadDelay
        self.readFile = readFile
    }

    var openThreads: [ProjectCommentThread] {
        threads.filter { $0.root.status == "open" }
            .sorted { (anchoredRanges[$0.id]?.location ?? .max) < (anchoredRanges[$1.id]?.location ?? .max) }
    }

    var resolvedThreads: [ProjectCommentThread] { threads.filter { $0.root.status == "resolved" } }

    /// The owner's unsent comments on this document, in text order (drafts
    /// whose passage is gone last).
    /// (`sorted` is stable: equal locations keep the order they were written.)
    var drafts: [ProjectCommentDraft] {
        draftStore.drafts(for: document.id).sorted {
            (draftRanges[$0.id]?.location ?? .max) < (draftRanges[$1.id]?.location ?? .max)
        }
    }

    /// A send is writing the drafts; the pane disables Send and the drafts.
    private(set) var isSending = false

    /// Drafts "Send N comments" delivers: still on the text, with a body.
    var sendableDraftCount: Int { readyDrafts.count }

    /// Drafts a send leaves behind: their passage is gone or their text is empty.
    var unsendableDraftCount: Int { draftStore.drafts(for: document.id).count - readyDrafts.count }

    private var readyDrafts: [ProjectCommentDraft] {
        draftStore.drafts(for: document.id).filter {
            draftRanges[$0.id] != nil && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var outdatedThreads: [ProjectCommentThread] { threads.filter { $0.root.status == "outdated" } }

    func threadID(at location: Int) -> Int64? {
        anchoredRanges.first { NSLocationInRange(location, $0.value) }?.key
    }

    // MARK: - Loading

    func load() async {
        let id = document.id
        do {
            let (fresh, comments) = try await dbPool.read { db in
                (try ProjectQueries.document(db, id: id), try ProjectQueries.comments(db, documentID: id))
            }
            if let fresh { document = fresh }
            threads = ProjectCommentThread.group(comments)
        } catch {
            errorMessage = "Could not load comments: \(error.localizedDescription)"
            return
        }
        guard let text = readDocumentText() else { return }
        let doc = DocumentRendering.render(text)
        rendered = doc
        renderVersion += 1
        draftRanges = locateDrafts(on: doc.text)
        let lost = reanchor(on: doc.text)
        if !lost.isEmpty { await markOutdated(lost) }
        await markRepliesRead()
    }

    private func readDocumentText() -> String? {
        do {
            let text = try readFile(document.fileURL(in: project))
            loadError = nil
            return text
        } catch {
            rendered = nil
            anchoredRanges = [:]
            draftRanges = [:]
            loadError = "Could not read \(document.relPath): \(error.localizedDescription)"
            return nil
        }
    }

    /// Locates every anchored open/resolved root; returns the open ones lost.
    /// A lost root with an unanswered owner reply stays open: marking it
    /// `outdated` would drop that reply from the agent's new-for-agent
    /// channels again right after `ProjectQueries.reply` reopened it. The
    /// agent answering (or resolving) is what lets it go `outdated` later.
    private func reanchor(on text: String) -> [Int64] {
        var ranges: [Int64: NSRange] = [:]
        var lost: [Int64] = []
        for thread in threads where thread.root.status != "outdated" {
            guard let anchor = thread.root.anchor else { continue }
            if let found = anchor.locate(in: text) {
                ranges[thread.id] = NSRange(found, in: text)
            } else if thread.root.isOpen && !thread.hasUnansweredOwnerReply {
                lost.append(thread.id)
            }
        }
        anchoredRanges = ranges
        return lost
    }

    private func markOutdated(_ ids: [Int64]) async {
        do {
            try await dbPool.write { db in
                for id in ids { try ProjectQueries.setStatus(db, commentID: id, status: "outdated") }
            }
            onOwnerWrite?(.document(document.id))
            await reloadThreads()
        } catch {
            errorMessage = "Could not mark lost comments outdated: \(error.localizedDescription)"
        }
    }

    private func markRepliesRead() async {
        let hasUnread = threads.contains { thread in
            thread.root.isUnreadForOwner || thread.replies.contains(where: \.isUnreadForOwner)
        }
        guard hasUnread else { return }
        let (projectID, documentID) = (project.id, document.id)
        do {
            try await dbPool.write { db in
                try ProjectQueries.markAgentCommentsRead(db, projectID: projectID, targetID: nil, documentID: documentID)
            }
            await reloadThreads()
        } catch {
            errorMessage = "Could not mark replies read: \(error.localizedDescription)"
        }
    }

    /// Re-reads the threads (the agent's DB-only writes) and anchors any new
    /// open root, without re-rendering the file or bumping `renderVersion`.
    /// - Parameter markRead: the document is on screen, so new agent replies
    ///   are marked read exactly as `load()` does.
    func refreshThreads(markRead: Bool) async {
        await reloadThreads()
        if let rendered { anchoredRanges = anchoredRangesAfterAdd(rendered.text) }
        if markRead { await markRepliesRead() }
    }

    private func reloadThreads() async {
        let id = document.id
        do {
            let comments = try await dbPool.read { try ProjectQueries.comments($0, documentID: id) }
            threads = ProjectCommentThread.group(comments)
        } catch {
            errorMessage = "Could not reload comments: \(error.localizedDescription)"
        }
    }

    private func locateDrafts(on text: String) -> [UUID: NSRange] {
        var ranges: [UUID: NSRange] = [:]
        for draft in draftStore.drafts(for: document.id) {
            if let found = draft.anchor.locate(in: text) { ranges[draft.id] = NSRange(found, in: text) }
        }
        return ranges
    }

    // MARK: - Drafts

    /// Keeps a comment on `selection` as a draft — nothing is written and the
    /// agent sees nothing until `sendDrafts`. Returns whether it was kept.
    @discardableResult
    func addDraft(body: String, selection: NSRange) -> Bool {
        guard let rendered, selection.length > 0,
              let range = Range(selection, in: rendered.text),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let anchor = CommentAnchor.make(text: rendered.text, range: range, headings: rendered.headingOffsets)
        let draft = ProjectCommentDraft(anchor: anchor, body: body)
        draftStore.add(draft, documentID: document.id)
        draftRanges[draft.id] = selection
        return true
    }

    func updateDraft(_ id: UUID, body: String) {
        draftStore.update(id, body: body, documentID: document.id)
    }

    func deleteDraft(_ id: UUID) {
        draftStore.remove([id], documentID: document.id)
        draftRanges[id] = nil
    }

    /// Writes every draft still on the text as an owner comment, all in one
    /// transaction, then drops them. A failure writes none and keeps them all.
    /// A draft emptied by an edit is skipped (kept). Returns how many were
    /// written (0 with nothing to send), or nil when the write failed or a
    /// send is already running — a second click must not write them twice.
    @discardableResult
    func sendDrafts() async -> Int? {
        guard !isSending else { return nil }
        let ready = readyDrafts
        guard !ready.isEmpty else { return 0 }
        isSending = true
        defer { isSending = false }
        let (projectID, documentID) = (project.id, document.id)
        let wrote = await ownerWrite { db in
            for draft in ready {
                _ = try ProjectQueries.addOwnerComment(
                    db, projectID: projectID, targetID: nil, documentID: documentID, anchor: draft.anchor, body: draft.body
                )
            }
        }
        guard wrote else { return nil }
        draftStore.remove(Set(ready.map(\.id)), documentID: documentID)
        for draft in ready { draftRanges[draft.id] = nil }
        if let rendered { anchoredRanges = anchoredRangesAfterAdd(rendered.text) }
        return ready.count
    }

    // MARK: - Owner actions

    /// - Returns: whether the reply was written; on `false` the composer keeps
    ///   the owner's draft and `errorMessage` says why (the `addComment` rule).
    @discardableResult
    func reply(to rootID: Int64, body: String) async -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await ownerWrite { db in _ = try ProjectQueries.reply(db, to: rootID, body: body) }
    }

    func resolve(_ rootID: Int64) async {
        await ownerWrite { db in try ProjectQueries.setStatus(db, commentID: rootID, status: "resolved") }
    }

    func reopen(_ rootID: Int64) async {
        await ownerWrite { db in try ProjectQueries.setStatus(db, commentID: rootID, status: "open") }
    }

    /// - Returns: whether the write committed; on failure `errorMessage` says why.
    @discardableResult
    private func ownerWrite(_ write: @escaping @Sendable (Database) throws -> Void) async -> Bool {
        do {
            try await dbPool.write(write)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
        errorMessage = nil
        onOwnerWrite?(.document(document.id))
        await reloadThreads()
        return true
    }

    private func anchoredRangesAfterAdd(_ text: String) -> [Int64: NSRange] {
        var ranges = anchoredRanges
        for thread in threads where ranges[thread.id] == nil && thread.root.isOpen {
            if let found = thread.root.anchor?.locate(in: text) { ranges[thread.id] = NSRange(found, in: text) }
        }
        return ranges
    }

    // MARK: - Watching

    func startWatching() {
        guard watcher == nil else { return }
        watcher = DocumentFileWatcher(url: document.fileURL(in: project)) { [weak self] in
            self?.fileDidChange()
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    /// Debounced: a burst of vnode events becomes one reload `reloadDelay`
    /// after the last one, so a half-written file is never re-anchored.
    func fileDidChange() {
        pendingReload?.cancel()
        let delay = reloadDelay
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }
}
