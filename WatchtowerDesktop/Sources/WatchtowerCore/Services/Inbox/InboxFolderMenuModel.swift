import Foundation
import GRDB

/// What one read of the menu sees: the tree, each folder's own count (the
/// numbers the menu shows, whose visible sum is the sidebar badge), how
/// many open artifacts each folder holds (Delete…'s summary), and what the
/// folder's entries are composed from (`InboxFolderEntries`): each folder's
/// artifacts with their row refs and the render-time check, Waiting for me's
/// and Needs approval's built-ins, and Needs approval's own cards by key.
package struct InboxFolderMenuSnapshot: Equatable, Sendable {
    package let tree: InboxFolderTree
    package let counts: [Int64: Int]
    package let artifacts: [Int64: Int]
    /// Each folder's open artifacts in the Inbox order. Never the
    /// `needs-approval` built-in's: those are drawn only through the
    /// approvals they show (`approvalArtifacts`), so a card of a closed
    /// approval is never on screen (APPROVAL-01).
    package let cards: [Int64: [AutomationOutputCard]]
    /// Each card's row refs (card id → refs).
    package let refs: [Int64: [InboxRef]]
    package let refState: InboxRefState
    package let waitingForMe: WaitingForMeState
    package let needsApproval: NeedsApprovalState
    /// The `needs-approval` built-in's living cards by key (`action:<id>`,
    /// `reminder:<id>`).
    package let approvalArtifacts: [String: AutomationOutputCard]
    /// The actions that wait on the owner now (`awaitingOwnerClause`, the
    /// badge's own predicate): the open approvals among the strip's rows,
    /// which also carry approved, running and recently decided ones.
    package let openActions: Set<Int64>
    /// The `idea-finder` built-in is indexed (`InboxFolderQueries.ideaFinderPresent`).
    package let ideaFinderPresent: Bool

    package init(
        tree: InboxFolderTree,
        counts: [Int64: Int] = [:],
        artifacts: [Int64: Int] = [:],
        cards: [Int64: [AutomationOutputCard]] = [:],
        refs: [Int64: [InboxRef]] = [:],
        refState: InboxRefState = InboxRefState(),
        waitingForMe: WaitingForMeState = WaitingForMeState(automationID: nil, messagesStandIn: true),
        needsApproval: NeedsApprovalState = .absent,
        approvalArtifacts: [String: AutomationOutputCard] = [:],
        openActions: Set<Int64> = [],
        ideaFinderPresent: Bool = false
    ) {
        self.tree = tree
        self.counts = counts
        self.artifacts = artifacts
        self.cards = cards
        self.refs = refs
        self.refState = refState
        self.waitingForMe = waitingForMe
        self.needsApproval = needsApproval
        self.approvalArtifacts = approvalArtifacts
        self.openActions = openActions
        self.ideaFinderPresent = ideaFinderPresent
    }

    /// One read, nothing written. Each source tolerates a schema that
    /// predates it; any other error is thrown.
    package static func read(_ db: Database, nowUTC: String) throws -> Self {
        let tree = try InboxFolderQueries.tree(db)
        let waitingForMe = try InboxFolderQueries.waitingForMe(db)
        let needsApproval = try InboxFolderQueries.needsApproval(db)
        // The stand-in rule (`WaitingForMeState`): a stale Waiting for me
        // list never counts beside the Messages entry it gives way to.
        var artifacts = waitingForMe.withoutStandInArtifacts(try InboxFolderQueries.artifactsByFolder(db, tree: tree))
        var approvalArtifacts: [String: AutomationOutputCard] = [:]
        if let approvalsID = needsApproval.automationID {
            for card in artifacts.values.joined() where card.automationID == approvalsID {
                if let key = card.outputKey { approvalArtifacts[key] = card }
            }
            artifacts = artifacts.mapValues { $0.filter { $0.automationID != approvalsID } }
        }
        let refs = InboxFolderCounts.refs(of: artifacts)
        let refState = try InboxRefState.read(db, refs: Array(refs.values.joined()), nowUTC: nowUTC)
        let legacy = try ActionStripViewModel.legacyCounts(
            db, nowUTC: nowUTC, tree: tree, messagesStandIn: waitingForMe.messagesStandIn)
        let counts = InboxFolderCounts.counts(
            tree: tree, artifacts: artifacts, refs: refs, refState: refState, legacy: legacy)
        let openActions = Set(try openActionIDs(db))
        return Self(tree: tree, counts: counts, artifacts: artifacts.mapValues(\.count), cards: artifacts,
                    refs: refs, refState: refState, waitingForMe: waitingForMe, needsApproval: needsApproval,
                    approvalArtifacts: approvalArtifacts, openActions: openActions,
                    ideaFinderPresent: try InboxFolderQueries.ideaFinderPresent(db))
    }

    /// The ids of the actions that wait on the owner; none on a database
    /// without the table.
    private static func openActionIDs(_ db: Database) throws -> [Int64] {
        do {
            return try Int64.fetchAll(
                db, sql: "SELECT id FROM agent_actions WHERE \(AgentActionQueries.awaitingOwnerClause)")
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return []
        }
    }
}

/// The Inbox's folder menu (spec "The Inbox screen" 1, "Writes: CLI only"):
/// the tree read from the database, and every change to it through
/// `watchtower inbox folders …` (`InboxFoldersCLI`) at the revision the menu
/// last read. The Desktop writes no folder table. A lost revision race
/// re-reads the tree once and says so; the write is never sent again by
/// itself. Owned by `ActionStripViewModel` (on `AppState`), so a write that
/// is still running when the Inbox leaves the screen lands in the same
/// state the Inbox finds when it comes back.
@MainActor
@Observable
package final class InboxFolderMenuModel {
    package private(set) var snapshot = InboxFolderMenuSnapshot(tree: .rootOnly)
    /// The selected folder; nil is the root.
    package private(set) var selection: Int64?
    /// The root's ⋯ Show Hidden Folders.
    package var showsHidden = false
    /// The menu's line: a lost race reloaded the tree, or the CLI is missing.
    package private(set) var note: InboxFolderMenuNote?
    /// A write runs: every other write and drag is ignored meanwhile.
    package private(set) var isBusy = false
    /// A refused write's message, cleared by the next edit.
    package private(set) var refusal: InboxFolderMenuRefusal?
    /// New Folder's or Rename's open field.
    package private(set) var draft: InboxFolderDraft?
    package private(set) var deleteConfirmation: InboxFolderDeleteSummary?
    package private(set) var dropIndicator: InboxFolderDrop?
    /// The folder a drag carries, from its start until it drops or ends.
    package private(set) var draggedID: Int64?
    /// The dropped folder while its move runs, drawn in its new place.
    package private(set) var pendingMove: (id: Int64, parent: Int64, position: Int)?
    package var pendingMoveID: Int64? { pendingMove?.id }
    /// The last read failed: the previous tree stays.
    package private(set) var readError: String?
    /// Needs approval's built-in is on (its ⋯ offers Turn Off, else Turn On).
    package var approvalsEnabled = true
    private var collapsed: Set<Int64> = []
    private var cliMissing = false
    private var noteTask: Task<Void, Never>?
    private var dragTask: Task<Void, Never>?

    private let dbPool: DatabasePool
    /// The CLI, found at each call; nil = no binary (edits off).
    private let runner: @MainActor () -> (any CLIRunnerProtocol)?
    private let clock: @Sendable () -> Date
    /// How long the "menu changed" line stays (spec: 5 seconds, or until the
    /// next drag).
    private let noteLifetime: Duration
    /// A drag SwiftUI never reports as ended (it was cancelled outside the
    /// menu) is forgotten after this long away from the menu.
    private let dragLifetime: Duration

    package init(
        dbPool: DatabasePool,
        runner: @escaping @MainActor () -> (any CLIRunnerProtocol)?,
        clock: @escaping @Sendable () -> Date = { Date() },
        noteLifetime: Duration = .seconds(5),
        dragLifetime: Duration = .seconds(60)
    ) {
        self.dbPool = dbPool
        self.runner = runner
        self.clock = clock
        self.noteLifetime = noteLifetime
        self.dragLifetime = dragLifetime
    }

    package var tree: InboxFolderTree { snapshot.tree }

    /// No edit, drag or write: the CLI is missing, a write runs, or no tree
    /// has been read yet (revision 0: nothing to compare-and-set against —
    /// before the first read, or a database without the folder tables).
    package var isReadOnly: Bool { cliMissing || isBusy || tree.revision < 1 }

    /// The folder the Inbox shows (the root when none is selected).
    package var selectedFolderID: Int64 { selection ?? tree.root.id }

    // MARK: - Reading

    /// Re-reads the tree and the counts. A failed read keeps the previous
    /// tree with the error in `readError`; it also re-checks the CLI.
    package func reload() async {
        let nowUTC = AutomationDates.format(clock())
        do {
            receive(try await dbPool.read { db in try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC) })
        } catch {
            receiveFailure(error.localizedDescription)
        }
    }

    /// A read made elsewhere in its own transaction (the Inbox's one
    /// `refresh()` read): taken as `reload` takes its own.
    package func receive(_ read: InboxFolderMenuSnapshot) {
        apply(read)
        readError = nil
        checkCLI()
    }

    /// That read failed: the previous tree stays.
    package func receiveFailure(_ message: String) {
        readError = message
        checkCLI()
    }

    /// Takes a read (`reload`, or a caller that read the tree in its own
    /// transaction): a selection, field or confirmation whose folder is gone
    /// goes with it.
    package func apply(_ read: InboxFolderMenuSnapshot) {
        snapshot = read
        let tree = read.tree
        if let selected = selection, tree.folder(selected) == nil { selection = nil }
        collapsed = collapsed.filter { tree.folder($0) != nil }
        // An open confirmation re-counts from this read (nil once the folder is gone).
        if let summary = deleteConfirmation { deleteConfirmation = deleteSummary(summary.folderID) }
        if let draft, !draftTargetExists(draft.target, in: tree) { self.draft = nil }
    }

    private func draftTargetExists(_ target: InboxFolderDraft.Target, in tree: InboxFolderTree) -> Bool {
        switch target {
        case let .create(parent): parent.map { tree.folder($0) != nil } ?? true
        case let .rename(id): tree.folder(id) != nil
        }
    }

    private func checkCLI() {
        cliMissing = runner() == nil
        if cliMissing {
            setNote(.cliUnavailable)
        } else if note == .cliUnavailable {
            note = nil
        }
    }

    // MARK: - What the menu draws

    package var content: InboxFolderMenuContent {
        var depths: [Int64: Int] = [:]
        let rows = shownFolders.map { folder -> InboxFolderRow in
            let depth = folder.parentID.flatMap { depths[$0].map { $0 + 1 } } ?? 0
            depths[folder.id] = depth
            return InboxFolderRow(
                id: folder.id, kind: folder.kind, title: folder.title, icon: folder.icon, depth: depth,
                count: snapshot.counts[folder.id] ?? 0, hidden: folder.hidden,
                isExpanded: !collapsed.contains(folder.id))
        }
        return InboxFolderMenuContent(
            rows: rows, selection: selectedFolderID,
            note: cliMissing ? .cliUnavailable : note,
            dropIndicator: dropIndicator, draggedID: draggedID, editsOff: isReadOnly,
            deleteConfirmation: deleteConfirmation, folderDraft: draft,
            refusal: draft == nil ? refusal : nil, pendingMoveID: pendingMoveID, showsHidden: showsHidden,
            icons: Self.icons, approvalsEnabled: approvalsEnabled)
    }

    /// The tree's folders in pre-order, the pending move's folder (with its
    /// subtree) already in its new place.
    private var shownFolders: [InboxFolder] {
        let folders = tree.folders
        guard let move = pendingMove, folders.contains(where: { $0.id == move.id }) else { return folders }
        var children: [Int64: [InboxFolder]] = [:]
        for folder in folders where folder.id != move.id {
            if let parent = folder.parentID { children[parent, default: []].append(folder) }
        }
        if let moved = folders.first(where: { $0.id == move.id }) {
            var siblings = children[move.parent] ?? []
            siblings.insert(moved, at: min(max(move.position, 0), siblings.count))
            children[move.parent] = siblings
        }
        var out: [InboxFolder] = []
        func visit(_ folder: InboxFolder, parent: Int64?) {
            out.append(InboxFolder(id: folder.id, kind: folder.kind, parentID: parent, slug: folder.slug,
                                   title: folder.title, icon: folder.icon, position: folder.position,
                                   hidden: folder.hidden))
            for child in children[folder.id] ?? [] { visit(child, parent: folder.id) }
        }
        visit(tree.root, parent: nil)
        return out
    }

    /// Icon ▸'s entries: the allowlist with the names the menu shows.
    package static let icons: [InboxFolderIcon] = InboxFolderIcons.all.map { symbol in
        InboxFolderIcon(symbol: symbol, label: label(symbol))
    }

    private static func label(_ symbol: String) -> String {
        switch symbol {
        case "person.2": "People"
        case "shippingbox": "Box"
        case "tray.full": "Full Tray"
        case "doc.text": "Document"
        case "bubble.left": "Chat"
        case "chart.bar": "Chart"
        case "checkmark.circle": "Check"
        case "exclamationmark.triangle": "Warning"
        default: symbol.prefix(1).uppercased() + symbol.dropFirst()
        }
    }

    // MARK: - Presses that write nothing

    package func select(_ id: Int64) {
        guard tree.folder(id) != nil else { return }
        selection = id == tree.root.id ? nil : id
    }

    package func toggleExpanded(_ id: Int64) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// New Folder (parent nil = the root) or New Folder Inside.
    package func beginCreate(parent: Int64?) {
        guard !isReadOnly else { return }
        refusal = nil
        deleteConfirmation = nil
        if let parent, parent != tree.root.id {
            collapsed.remove(parent)
            draft = InboxFolderDraft(.create(parent: parent), title: "")
        } else {
            draft = InboxFolderDraft(.create(parent: nil), title: "")
        }
    }

    package func beginRename(_ id: Int64) {
        guard !isReadOnly, let folder = tree.folder(id), folder.kind == .owner else { return }
        refusal = nil
        deleteConfirmation = nil
        draft = InboxFolderDraft(.rename(id), title: folder.title)
    }

    /// Typing clears the field's refusal: the next edit.
    package func editDraft(_ title: String) {
        guard var draft else { return }
        draft.title = title
        draft.error = nil
        self.draft = draft
    }

    package func cancelDraft() {
        draft = nil
    }

    /// Delete…'s inline confirmation: what moves up to the parent.
    package func askDelete(_ id: Int64) {
        guard !isReadOnly, let summary = deleteSummary(id) else { return }
        refusal = nil
        draft = nil
        deleteConfirmation = summary
    }

    package func cancelDelete() {
        deleteConfirmation = nil
    }

    /// The child folders, the automations routed here and the open artifacts
    /// in it, as the tree read them.
    package func deleteSummary(_ id: Int64) -> InboxFolderDeleteSummary? {
        let tree = tree
        guard let folder = tree.folder(id), folder.kind == .owner, let parent = folder.parentID else { return nil }
        return InboxFolderDeleteSummary(
            folderID: id, title: folder.title,
            folders: tree.folders.filter { $0.parentID == id }.count,
            automations: tree.routes.values.filter { $0 == id }.count,
            artifacts: snapshot.artifacts[id] ?? 0,
            parentTitle: tree.folder(parent)?.title ?? tree.root.title)
    }

    // MARK: - Writes

    /// Sends the open field: a create or a rename. A refusal keeps the field
    /// open with the CLI's message.
    package func commitDraft() async {
        guard let draft else { return }
        switch draft.target {
        case let .create(parent): await create(title: draft.title, parent: parent)
        case let .rename(id): await rename(id, title: draft.title)
        }
    }

    package func create(title: String, parent: Int64?) async {
        let parent = parent == tree.root.id ? nil : parent
        await write(row: parent, fromDraft: true) { cli, revision in
            _ = try await cli.create(title: title, parent: parent, expectRevision: revision)
        }
    }

    package func rename(_ id: Int64, title: String) async {
        await write(row: id, fromDraft: true) { cli, revision in
            _ = try await cli.update(id, title: title, expectRevision: revision)
        }
    }

    package func setIcon(_ id: Int64, icon: String) async {
        await write(row: id) { cli, revision in
            _ = try await cli.update(id, icon: icon, expectRevision: revision)
        }
    }

    package func setHidden(_ id: Int64, hidden: Bool) async {
        await write(row: id) { cli, revision in
            _ = try await cli.update(id, visibility: hidden ? .hidden : .shown, expectRevision: revision)
        }
    }

    package func move(_ id: Int64, toParent parent: Int64, position: Int) async {
        guard !isBusy else { return }
        pendingMove = (id, parent, position)
        defer { pendingMove = nil }
        await write(row: id) { cli, revision in
            _ = try await cli.move(id, parent: parent, position: position, expectRevision: revision)
        }
    }

    /// Deletes a folder; its contents move up. The selection, when it was
    /// this folder, moves to its parent.
    package func delete(_ id: Int64) async {
        let parent = tree.folder(id)?.parentID
        // The reload after the write drops a selection that is gone.
        let wasSelected = selection == id
        let landed = await write(row: id) { cli, revision in
            _ = try await cli.delete(id, expectRevision: revision)
        }
        guard landed else { return }
        deleteConfirmation = nil
        if wasSelected, let parent { select(parent) }
    }

    /// Sends automation `automationID`'s artifacts to folder `folderID`
    /// (the artifact ⋯'s Move to Folder ▸, a save from **+ New Artifact…**):
    /// one `route` at the read revision, never retried. Nil when it landed
    /// (the tree re-read); else the reason, for the caller to show on its
    /// own line — the menu shows only what concerns the menu (a lost race's
    /// note, the missing CLI).
    package func route(_ automationID: Int64, to folderID: Int64) async -> String? {
        guard !isBusy else { return Self.routeBusy }
        guard tree.revision >= 1 else { return Self.routeNotRead }
        var reason: String?
        await write(row: nil, onFailure: { error in
            reason = error == .menuChanged ? Self.routeMenuChanged : (error.errorDescription ?? "")
        }, { cli, revision in
            _ = try await cli.route(automationID: automationID, to: .folder(folderID), expectRevision: revision)
        })
        return reason
    }

    /// A row ⋯ press the caller carried out failed (Needs approval's, from
    /// the menu while another folder is open): its reason on that row, like
    /// the menu's own refusals.
    package func showRefusal(_ message: String, on folderID: Int64) {
        refusal = InboxFolderMenuRefusal(folderID: folderID, message: message)
    }

    nonisolated package static let routeBusy = "another change to the Inbox menu is running — try again"
    nonisolated package static let routeNotRead = "the Inbox menu is not read yet — try again"
    nonisolated package static let routeMenuChanged = "the Inbox menu changed — it was reloaded, try again"

    /// One write at the read revision. Returns whether it landed. Never
    /// retried: a lost race re-reads once and sets the note; a refusal
    /// leaves the tree as it is; an undecodable answer may have landed, so
    /// it re-reads and keeps the message. With `onFailure` the refusal is
    /// the caller's to show, not the menu's.
    @discardableResult
    private func write(
        row: Int64?,
        fromDraft: Bool = false,
        onFailure: ((InboxFoldersCLIError) -> Void)? = nil,
        _ call: @escaping (InboxFoldersCLI, Int64) async throws -> Void
    ) async -> Bool {
        guard !isBusy, tree.revision >= 1 else { return false }
        guard let runner = runner() else {
            cliMissing = true
            setNote(.cliUnavailable)
            onFailure?(.cliUnavailable)
            return false
        }
        cliMissing = false
        isBusy = true
        // A caller-shown write (a route) leaves the menu's own line alone.
        if onFailure == nil { refusal = nil }
        defer { isBusy = false }
        do {
            try await call(InboxFoldersCLI(runner: runner), tree.revision)
        } catch {
            let mapped = InboxFoldersCLI.map(error)
            await failed(mapped, row: row, fromDraft: fromDraft, menuShowsRefusal: onFailure == nil)
            onFailure?(mapped)
            return false
        }
        if fromDraft { draft = nil }
        await reload()
        return true
    }

    private func failed(
        _ error: InboxFoldersCLIError, row: Int64?, fromDraft: Bool, menuShowsRefusal: Bool = true
    ) async {
        switch error {
        case .menuChanged:
            await reload()
            setNote(.menuChanged)
        case let .refused(message):
            guard menuShowsRefusal else { return }
            if fromDraft, draft != nil {
                draft?.error = message
            } else {
                refusal = InboxFolderMenuRefusal(folderID: row, message: message)
            }
        case .cliUnavailable:
            cliMissing = true
            setNote(.cliUnavailable)
        case .unexpectedAnswer:
            if fromDraft { draft = nil }
            await reload()
            guard menuShowsRefusal else { return }
            refusal = InboxFolderMenuRefusal(folderID: row, message: error.errorDescription ?? "")
        }
    }

    private func setNote(_ value: InboxFolderMenuNote) {
        noteTask?.cancel()
        note = value
        guard value == .menuChanged else { return }
        let lifetime = noteLifetime
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, self?.note == .menuChanged else { return }
            self?.note = nil
        }
    }

    // MARK: - Drag

    /// A drag starts: the "menu changed" line goes (spec: until the next drag).
    package func beginDrag(_ id: Int64) {
        guard !isReadOnly, tree.folder(id)?.kind == .owner else { return }
        if note == .menuChanged { note = nil }
        refusal = nil
        draggedID = id
        armDragLifetime(id)
    }

    /// (Re)starts the clock that forgets a drag nobody reports as ended. Each
    /// move over the menu re-arms it, so only time spent outside counts.
    private func armDragLifetime(_ id: Int64) {
        dragTask?.cancel()
        let lifetime = dragLifetime
        dragTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, self?.draggedID == id else { return }
            self?.endDrag()
        }
    }

    /// The drag is over `drop`: its indicator, only where the drop is allowed.
    /// Written only on a change: SwiftUI calls this on every pointer move.
    package func dragOver(_ drop: InboxFolderDrop?) {
        if let draggedID { armDragLifetime(draggedID) }
        var allowed: InboxFolderDrop?
        if let draggedID, let drop, canDrop(draggedID, onto: drop) { allowed = drop }
        if dropIndicator != allowed { dropIndicator = allowed }
    }

    package func endDrag() {
        dragTask?.cancel()
        dragTask = nil
        draggedID = nil
        dropIndicator = nil
    }

    /// Drops the dragged folder: only the folder of the live drag (`id` is
    /// the one the drop carried), and refused locally (no CLI call) where
    /// `canDrop` says no; else one `move`.
    package func drop(_ id: Int64, onto drop: InboxFolderDrop) async {
        let live = draggedID == id
        endDrag()
        guard live, !isReadOnly, let target = moveTarget(id, onto: drop) else { return }
        await move(id, toParent: target.parent, position: target.position)
    }

    /// Only an owner folder moves; nothing goes above or into Needs
    /// approval, into its own subtree, or deeper than three below the root.
    package func canDrop(_ id: Int64, onto drop: InboxFolderDrop) -> Bool {
        moveTarget(id, onto: drop) != nil
    }

    /// The `move` arguments for a drop: before a folder = its index among
    /// its siblings (Needs approval included, the dragged one left out);
    /// into a folder = its last child.
    package func moveTarget(_ id: Int64, onto drop: InboxFolderDrop) -> (parent: Int64, position: Int)? {
        let tree = tree
        guard id != drop.targetID, let folder = tree.folder(id), folder.kind == .owner,
              let target = tree.folder(drop.targetID) else { return nil }
        let parent: Int64
        switch drop.placement {
        case .before:
            guard target.kind == .owner, let targetParent = target.parentID else { return nil }
            parent = targetParent
        case .into:
            guard target.kind != .approvals else { return nil }
            parent = target.id
        }
        guard !isWithin(parent, of: id, tree), depth(parent, tree) + 1 + height(id, tree) <= Self.maxDepth else {
            return nil
        }
        let siblings = tree.folders.filter { $0.parentID == parent && $0.id != id }.map(\.id)
        switch drop.placement {
        case .before: return (parent, siblings.firstIndex(of: target.id) ?? siblings.count)
        case .into: return (parent, siblings.count)
        }
    }

    /// Owner folders nest at most this deep below the root (Go's `MaxDepth`).
    package static let maxDepth = 3

    private func depth(_ id: Int64, _ tree: InboxFolderTree) -> Int {
        var depth = 0
        var current = tree.folder(id)?.parentID
        while let parent = current, depth <= tree.folders.count {
            depth += 1
            current = tree.folder(parent)?.parentID
        }
        return depth
    }

    /// How many levels sit below `id` (0 for a folder without children).
    private func height(_ id: Int64, _ tree: InboxFolderTree) -> Int {
        let children = tree.folders.filter { $0.parentID == id }
        return children.map { 1 + height($0.id, tree) }.max() ?? 0
    }

    /// `id` is `ancestor` or below it.
    private func isWithin(_ id: Int64, of ancestor: Int64, _ tree: InboxFolderTree) -> Bool {
        var current: Int64? = id
        var steps = 0
        while let folder = current, steps <= tree.folders.count {
            if folder == ancestor { return true }
            current = tree.folder(folder)?.parentID
            steps += 1
        }
        return false
    }

    // MARK: - The ⋯ menus

    /// A folder ⋯ or root ⋯ press the menu carries out itself. The rest (the
    /// panes, Needs approval's entries) is the caller's; returns false then.
    @discardableResult
    package func perform(_ command: InboxMenuCommand, folderID: Int64) async -> Bool {
        switch command {
        case .rename: beginRename(folderID)
        case let .icon(symbol): await setIcon(folderID, icon: symbol)
        case .newFolderInside: beginCreate(parent: folderID)
        case .hide: await setHidden(folderID, hidden: true)
        case .show: await setHidden(folderID, hidden: false)
        case .deleteFolder: askDelete(folderID)
        case .showHiddenFolders: showsHidden = true
        case .hideHiddenFolders: showsHidden = false
        case .newFolder: beginCreate(parent: nil)
        default: return false
        }
        return true
    }
}
