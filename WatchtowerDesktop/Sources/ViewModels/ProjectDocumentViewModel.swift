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
    private(set) var loadError: String?
    var errorMessage: String?
    /// The reload a file change scheduled (exposed for tests).
    private(set) var pendingReload: Task<Void, Never>?
    /// Bumped on every successful `load()`. A composer captures this when it
    /// opens; `addComment` refuses to write if the version has since moved,
    /// since the selection it holds was computed against a render that no
    /// longer exists (a reload swapped `rendered` for a fresh one).
    private(set) var renderVersion = 0

    var onOwnerWrite: ((ProjectSubject) -> Void)?

    private let dbPool: DatabasePool
    private let readFile: (URL) throws -> String
    private let reloadDelay: Duration
    private var watcher: DocumentFileWatcher?

    init(
        dbPool: DatabasePool,
        project: Project,
        document: ProjectDocument,
        reloadDelay: Duration = .milliseconds(500),
        readFile: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) {
        self.dbPool = dbPool
        self.project = project
        self.document = document
        self.reloadDelay = reloadDelay
        self.readFile = readFile
    }

    var openThreads: [ProjectCommentThread] {
        threads.filter { $0.root.status == "open" }
            .sorted { (anchoredRanges[$0.id]?.location ?? .max) < (anchoredRanges[$1.id]?.location ?? .max) }
    }

    var resolvedThreads: [ProjectCommentThread] { threads.filter { $0.root.status == "resolved" } }
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
            loadError = "Could not read \(document.relPath): \(error.localizedDescription)"
            return nil
        }
    }

    /// Locates every anchored open/resolved root; returns the open ones lost.
    private func reanchor(on text: String) -> [Int64] {
        var ranges: [Int64: NSRange] = [:]
        var lost: [Int64] = []
        for thread in threads where thread.root.status != "outdated" {
            guard let anchor = thread.root.anchor else { continue }
            if let found = anchor.locate(in: text) {
                ranges[thread.id] = NSRange(found, in: text)
            } else if thread.root.isOpen {
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

    private func reloadThreads() async {
        let id = document.id
        do {
            let comments = try await dbPool.read { try ProjectQueries.comments($0, documentID: id) }
            threads = ProjectCommentThread.group(comments)
        } catch {
            errorMessage = "Could not reload comments: \(error.localizedDescription)"
        }
    }

    // MARK: - Owner actions

    /// - Parameter renderVersion: the version the caller's selection was computed against
    ///   (typically captured when a composer opened). `nil` skips the staleness check — used
    ///   by callers that don't hold a composer across an `await` boundary. A mismatch means the
    ///   file reloaded since the selection was made: the write is refused, the selection is
    ///   surely wrong on the new text, and the caller keeps its draft so the owner can re-select.
    /// - Returns: whether a comment was written, so a composer knows whether to close/clear.
    ///   A failed write returns `false` (with `errorMessage` set) so the owner's draft survives.
    @discardableResult
    func addComment(body: String, selection: NSRange, renderVersion: Int? = nil) async -> Bool {
        if let renderVersion, renderVersion != self.renderVersion {
            errorMessage = "The document changed — select the passage again."
            return false
        }
        guard let rendered, selection.length > 0,
              let range = Range(selection, in: rendered.text),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let anchor = CommentAnchor.make(text: rendered.text, range: range, headings: rendered.headingOffsets)
        let (projectID, documentID) = (project.id, document.id)
        let wrote = await ownerWrite { db in
            _ = try ProjectQueries.addOwnerComment(
                db, projectID: projectID, targetID: nil, documentID: documentID, anchor: anchor, body: body
            )
        }
        guard wrote else { return false }
        anchoredRanges = anchoredRangesAfterAdd(rendered.text)
        return true
    }

    func reply(to rootID: Int64, body: String) async {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await ownerWrite { db in _ = try ProjectQueries.reply(db, to: rootID, body: body) }
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
