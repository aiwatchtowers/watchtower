import Foundation
import GRDB

// MARK: - Memory browser ViewModel
//
// Drives the Memory tab: node list + FTS search from the SQLite index,
// bodies/backlinks straight from the vault files, history from the vault's
// git repo, and owner edits written back to the files. The app never writes
// memory_* tables or git — the daemon pipeline reconciles the index and
// commits owner edits (MEM-02/03).

/// Everything the detail pane shows for the selected node.
struct MemoryNodeDetail: Equatable {
    let node: MemoryNodeListItem
    /// Raw vault file contents (frontmatter included) — what the editor edits.
    let raw: String
    /// Non-nil when the vault file could not be read. The body area shows it
    /// and editing is disabled — a failed read must never round-trip into an
    /// empty overwrite of the real file.
    let fileReadError: String?
    let renderedBody: String // body with [[links]] converted to tappable URLs
    let aliases: [String]
    let backlinks: [MemoryBacklink]
    /// Belief subject entity, resolved for the header link ("" / nil otherwise).
    let subjectID: String?
    let subjectTitle: String
    var history: [MemoryCommit] = [] // filled asynchronously

    var isEditable: Bool { fileReadError == nil }

    /// Manual importance override parsed from the raw file's frontmatter, nil
    /// when unset (the merged `node.importanceScore` is the computed value in
    /// that case) or when the frontmatter fence itself can't be parsed.
    var importanceOverride: Double? {
        MemoryMarkdown.currentImportanceOverride(frontmatter: MemoryMarkdown.splitFrontmatter(raw).frontmatter)
    }

    /// The Importance section is only editable when the file has a real
    /// frontmatter fence to patch — same degrade-not-guess rule as `isEditable`.
    var canEditImportance: Bool {
        isEditable && !MemoryMarkdown.splitFrontmatter(raw).frontmatter.isEmpty
    }
}

@MainActor
@Observable
final class MemoryViewModel {
    var nodes: [MemoryNodeListItem] = []
    var typeCounts: [String: Int] = [:]
    var typeFilter: String? // nil = all; "entity"|"episode"|"rollup"|"belief"
    var sort: MemorySort = .recent
    var searchText = ""
    var searchHits: [MemorySearchHit] = []
    var beliefs: [MemoryBeliefRow] = []
    var selectedID: String?
    var detail: MemoryNodeDetail?
    var error: String?

    // Editor state
    var isEditing = false
    var editorText = ""
    var editorError: String?

    // Focus editor state (owner-authored vault-root focus.md — a separate
    // whole-file editor from the per-node one above, same write mechanics).
    var isFocusEditing = false
    var focusEditorText = ""
    var focusEditorError: String?
    var isSavingFocus = false

    // Importance override state (a separate, smaller edit path from the
    // whole-file editor above — see saveImportanceOverride).
    var importanceOverrideInput: Double = 0
    var importanceError: String?

    private let dbPool: DatabasePool
    private var searchTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    /// Reverse wiki-link graph: target node id → source node ids, rebuilt by
    /// scanning vault files off-main.
    private var backlinkGraph: [String: Set<String>] = [:]

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// The vault directory sits next to the workspace DB (Go WorkspaceDir()).
    nonisolated var vaultURL: URL {
        URL(fileURLWithPath: dbPool.path)
            .deletingLastPathComponent()
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// The cross-process memory lock the Go pipeline flocks (vault.Lock).
    nonisolated private var lockURL: URL {
        URL(fileURLWithPath: dbPool.path)
            .deletingLastPathComponent()
            .appendingPathComponent("memory.lock")
    }

    var vaultExists: Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    /// Beliefs dashboard header numbers, derived from the loaded rows.
    var beliefStats: MemoryBeliefStats {
        var stats = MemoryBeliefStats()
        stats.total = beliefs.count
        for b in beliefs {
            if b.status == "shaken" { stats.shaken += 1 }
            if b.isDisputed { stats.disputed += 1 }
        }
        if !beliefs.isEmpty {
            stats.averageConfidence = beliefs.map(\.confidence).reduce(0, +) / Double(beliefs.count)
        }
        return stats
    }

    /// Nodes the list shows for the current type filter.
    var filteredNodes: [MemoryNodeListItem] {
        guard let typeFilter else { return nodes }
        return nodes.filter { $0.type == typeFilter }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Loading

    // No ValueObservation here on purpose: the app never writes memory_*
    // tables (MEM-02) and GRDB can't see the daemon's cross-process writes,
    // so refresh-on-appear is the whole story.
    func refresh() async {
        do {
            let (nodes, counts, beliefs) = try await dbPool.read { [sort] db in
                (try MemoryQueries.fetchNodes(db, sort: sort),
                 try MemoryQueries.fetchTypeCounts(db),
                 try MemoryQueries.fetchBeliefs(db))
            }
            self.nodes = nodes
            self.typeCounts = counts
            self.beliefs = beliefs
            self.error = nil
        } catch {
            self.error = "Failed to load memory index: \(error.localizedDescription)"
        }
        await rebuildBacklinkGraph()
        if let selectedID, detail == nil {
            await select(id: selectedID)
        }
    }

    // MARK: - Search

    func searchChanged() {
        searchTask?.cancel()
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchHits = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200)) // debounce typing
            guard let self, !Task.isCancelled else { return }
            do {
                let hits = try await self.dbPool.read { db in
                    try MemoryQueries.searchNodes(db, query: query)
                }
                if !Task.isCancelled { self.searchHits = hits }
            } catch {
                if !Task.isCancelled { self.searchHits = [] }
            }
        }
    }

    // MARK: - Selection / navigation

    func select(id: String) async {
        selectedID = id
        isEditing = false
        editorError = nil
        importanceError = nil
        historyTask?.cancel()
        do {
            guard let node = try await dbPool.read({ db in
                try MemoryQueries.fetchNode(db, id: id)
            }) else {
                guard selectedID == id else { return }
                detail = nil
                error = "Node \(id) is not in the index (run `watchtower memory reindex`?)"
                return
            }
            let fileURL = vaultURL.appendingPathComponent(node.path)
            var fileReadError: String?
            var raw = ""
            do {
                raw = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                // A missing/unreadable file is NOT an empty node — flag it so
                // the pane explains and editing is disabled (an empty editor
                // must never overwrite the real file).
                fileReadError = "Cannot read \(node.path): \(error.localizedDescription)"
            }
            let body = MemoryMarkdown.splitFrontmatter(raw).body
            let links = MemoryMarkdown.parseWikiLinks(body)

            // Resolve link targets to titles so label-less [[id]] links render readably.
            let targets = Set(links.map(\.target))
            let subjectID = node.isBelief && !node.subject.isEmpty ? node.subject : nil
            typealias DetailReads = ([String: String], [String], [MemoryBacklink], String)
            let (resolved, aliases, backlinkItems, subjectTitle) = try await dbPool.read { [backlinkGraph] db -> DetailReads in
                var resolved: [String: String] = [:] // target -> display title
                for target in targets {
                    if let nodeID = try MemoryQueries.resolveNodeID(db, target: target) {
                        let title = try MemoryQueries.fetchTitle(db, id: nodeID) ?? ""
                        resolved[target] = title.isEmpty ? nodeID : title
                    }
                }
                let aliases = try MemoryQueries.fetchAliases(db, nodeID: node.id)
                var backlinkItems: [MemoryBacklink] = []
                for source in (backlinkGraph[node.id] ?? []).sorted() {
                    guard let item = try MemoryQueries.fetchNode(db, id: source) else { continue }
                    backlinkItems.append(MemoryBacklink(id: source, title: item.displayTitle, type: item.type))
                }
                var subjectTitle = ""
                if let subjectID {
                    let title = try MemoryQueries.fetchTitle(db, id: subjectID) ?? ""
                    subjectTitle = title.isEmpty ? subjectID : title
                }
                return (resolved, aliases, backlinkItems, subjectTitle)
            }

            // A newer selection may have landed while we awaited — don't
            // clobber it with this stale node.
            guard selectedID == id else { return }

            let rendered = MemoryMarkdown.convertWikiLinks(in: body) { link in
                guard let title = resolved[link.target] else { return nil }
                return link.label.isEmpty ? title : link.label
            }
            detail = MemoryNodeDetail(
                node: node,
                raw: raw,
                fileReadError: fileReadError,
                renderedBody: rendered,
                aliases: aliases,
                backlinks: backlinkItems,
                subjectID: subjectID,
                subjectTitle: subjectTitle
            )
            importanceOverrideInput = detail?.importanceOverride ?? 0
            error = nil
            loadHistory(for: node)
        } catch {
            guard selectedID == id else { return }
            self.error = "Failed to open node: \(error.localizedDescription)"
        }
    }

    /// Handles a tap on a rendered wiki-link.
    func openWikiLink(url: URL) {
        guard let target = MemoryMarkdown.linkTarget(from: url) else { return }
        Task {
            let resolved = try? await dbPool.read { db in
                try MemoryQueries.resolveNodeID(db, target: target)
            }
            if let id = resolved {
                await select(id: id)
            }
        }
    }

    // MARK: - Backlinks

    /// Scans every vault file for wiki-links and inverts them. Alias targets
    /// resolve through the index so `[[situation:23]]` counts as a link to its
    /// episode. Runs off-main; the vault is a few hundred small files.
    private func rebuildBacklinkGraph() async {
        let vault = vaultURL
        let scanned: [String: Set<String>] = await Task.detached(priority: .utility) {
            var graph: [String: Set<String>] = [:] // raw target -> source ids
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: vault, includingPropertiesForKeys: nil) else {
                return graph
            }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "md" else { continue }
                let sourceID = url.deletingPathExtension().lastPathComponent
                // map.md / index.md are mechanical renders, not nodes.
                guard sourceID.contains("_") else { continue }
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let body = MemoryMarkdown.splitFrontmatter(raw).body
                for link in MemoryMarkdown.parseWikiLinks(body) {
                    graph[link.target, default: []].insert(sourceID)
                }
            }
            return graph
        }.value

        // Fold alias targets onto node ids.
        let idPrefixes = ["ent_", "ep_", "sum_", "bel_"]
        let aliasTargets = scanned.keys.filter { target in
            !idPrefixes.contains { target.hasPrefix($0) }
        }
        var resolvedAliases: [String: String] = [:]
        if !aliasTargets.isEmpty {
            resolvedAliases = (try? await dbPool.read { db in
                var out: [String: String] = [:]
                for target in aliasTargets {
                    if let id = try MemoryQueries.resolveNodeID(db, target: target) {
                        out[target] = id
                    }
                }
                return out
            }) ?? [:]
        }
        var graph: [String: Set<String>] = [:]
        for (target, sources) in scanned {
            let nodeID = resolvedAliases[target] ?? target
            graph[nodeID, default: []].formUnion(sources)
        }
        // A node linking to itself is noise, not a backlink.
        for (target, sources) in graph {
            graph[target] = sources.subtracting([target])
        }
        backlinkGraph = graph
    }

    // MARK: - History (vault git log)

    private func loadHistory(for node: MemoryNodeListItem) {
        let vault = vaultURL
        guard FileManager.default.fileExists(atPath: vault.appendingPathComponent(".git").path) else {
            return
        }
        historyTask = Task { [weak self] in
            let commits = await MemoryVaultGit.log(vault: vault, path: node.path)
            guard let self, !Task.isCancelled else { return }
            if self.detail?.node.id == node.id {
                self.detail?.history = commits
            }
        }
    }

    // MARK: - Locked vault writes

    /// Writes `text` to `fileURL` under the cross-process memory lock (the Go
    /// pipeline's `vault.Lock`, taken here as a non-blocking flock) with an
    /// atomic write — the one shared implementation behind every vault write
    /// path (`saveEdit`, `saveFocusRaw`, `saveImportanceOverride`, all of
    /// which previously triplicated this exact block; round-1 review panel
    /// nit). Returns the user-facing error message on failure, nil on
    /// success; callers keep their own distinct state handling (which flag
    /// to clear, whether to reselect/reload).
    private func lockedVaultWrite(_ text: String, to fileURL: URL) async -> String? {
        let lockPath = lockURL.path
        return await Task.detached(priority: .userInitiated) {
            let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else {
                return "Cannot open memory lock: \(String(cString: strerror(errno)))"
            }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                return "A memory run is in progress — try again in a moment."
            }
            defer { flock(fd, LOCK_UN) }
            do {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return "Save failed: \(error.localizedDescription)"
            }
        }.value
    }

    // MARK: - Editing (MEM-03 owner edits)

    func startEditing() {
        guard let detail, detail.isEditable else { return }
        editorText = detail.raw
        editorError = nil
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        editorError = nil
    }

    /// Writes the edited file back to the vault under the cross-process memory
    /// lock. The write is the whole owner edit — the next pipeline run commits
    /// it (MEM-03); a file with damaged frontmatter is quarantined (skipped,
    /// never deleted), so a bad edit can cost the node's index row but not the
    /// text.
    func saveEdit() async {
        guard let detail, detail.isEditable else { return }
        let fileURL = vaultURL.appendingPathComponent(detail.node.path)

        if let writeError = await lockedVaultWrite(editorText, to: fileURL) {
            editorError = writeError
            return
        }
        isEditing = false
        editorError = nil
        await rebuildBacklinkGraph()
        await select(id: detail.node.id)
    }

    // MARK: - Focus editing (owner-authored focus.md salience directives)

    /// Raw contents of the vault-root `focus.md`, or "" when the file doesn't
    /// exist yet — a missing file is not an error here (unlike the per-node
    /// editor's `fileReadError`), it just means no directives have been
    /// written. Any OTHER failure (EACCES, the path being a directory, a
    /// decode failure, …) now PROPAGATES instead of collapsing into "" —
    /// round-1 review panel, HIGH: the previous `try? … ?? ""` made a real
    /// read error indistinguishable from "missing", so `beginFocusEditing`
    /// would open an editable sheet pre-filled with the template and Save
    /// would silently overwrite the real file. Template seeding for a fresh
    /// editor is `beginFocusEditing`'s job, not this method's — it never
    /// writes anything.
    func loadFocusRaw() async throws -> String {
        let fileURL = vaultURL.appendingPathComponent("focus.md")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "" }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// The empty-file scaffold the Focus editor pre-fills (never written
    /// to disk until the owner saves) — VM-owned so Views depend on the VM,
    /// not on a sibling View's constant (house layering).
    static let focusTemplate = "# Focus\n\n## Now\n\n## Cooled\n"
    /// Loads focus.md and opens the editor sheet — the VM-owned counterpart
    /// of the per-node editor's `startEditing` (style reviewer: this used to
    /// live in `MemoryView` as a private view function). A missing file
    /// pre-fills the fixed template (nothing is written to disk until Save);
    /// a real read error sets `focusEditorError` and leaves the sheet CLOSED
    /// — mirroring the per-node editor's `fileReadError`/`isEditable` guard,
    /// so an unreadable focus.md can never open editable and have Save
    /// clobber it.
    func beginFocusEditing() async {
        do {
            let raw = try await loadFocusRaw()
            focusEditorText = raw.isEmpty ? Self.focusTemplate : raw
            focusEditorError = nil
            isFocusEditing = true
        } catch {
            focusEditorError = "Cannot read focus.md: \(error.localizedDescription)"
            isFocusEditing = false
        }
    }

    func cancelFocusEditing() {
        isFocusEditing = false
        focusEditorError = nil
    }

    /// Writes `focus.md` back to the vault root under the same cross-process
    /// memory lock and atomic-write mechanics as `saveEdit` — the next memory
    /// run's owner-edit commit (MEM-03) and focus-salience step pick it up.
    func saveFocusRaw(_ text: String) async {
        guard !isSavingFocus else { return }
        isSavingFocus = true
        defer { isSavingFocus = false }

        let fileURL = vaultURL.appendingPathComponent("focus.md")

        if let writeError = await lockedVaultWrite(text, to: fileURL) {
            focusEditorError = writeError
            return
        }
        focusEditorError = nil
        isFocusEditing = false
    }

    /// Sets or clears the node's manual importance override by patching just
    /// the `importance_override:` frontmatter line — unlike `saveEdit`, this
    /// never opens the whole-file editor sheet. Same MEM-03 contract: the
    /// write is the whole owner edit, the next pipeline run commits it and (on
    /// a clear) recomputes `memory_nodes.importance_score` from scratch —
    /// `detail.node.importanceScore` won't reflect a clear/set until then.
    /// `value == nil` clears the override.
    func saveImportanceOverride(value: Double?) async {
        guard let detail, detail.canEditImportance else { return }
        let (frontmatter, body) = MemoryMarkdown.splitFrontmatter(detail.raw)
        let patched = MemoryMarkdown.patchImportanceOverride(frontmatter: frontmatter, value: value)
        let newRaw = "---\n\(patched)\n---\n\(body)"
        guard newRaw != detail.raw else { return } // no-op: nothing actually changed
        let fileURL = vaultURL.appendingPathComponent(detail.node.path)

        if let writeError = await lockedVaultWrite(newRaw, to: fileURL) {
            importanceError = writeError
            return
        }
        importanceError = nil
        await select(id: detail.node.id)
    }
}
