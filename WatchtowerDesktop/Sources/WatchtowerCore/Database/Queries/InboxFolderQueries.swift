import Foundation
import GRDB

/// One folder of the Inbox menu (`inbox_folders`, migration 00175). The
/// Desktop only reads these rows: every write goes through
/// `watchtower inbox folders …` (`InboxFoldersCLI`).
package struct InboxFolder: Identifiable, Equatable, Sendable {
    /// The column's CHECK values: the one root, the one Needs approval, the
    /// owner's own folders.
    package enum Kind: String, Equatable, Sendable {
        case root, approvals, owner
    }

    package let id: Int64
    package let kind: Kind
    /// nil only for the root.
    package let parentID: Int64?
    package let slug: String
    package let title: String
    /// An SF Symbol of `InboxFolderIcons`; empty draws `folder`.
    package let icon: String
    package let position: Int
    package let hidden: Bool

    package init(
        id: Int64,
        kind: Kind,
        parentID: Int64?,
        slug: String,
        title: String,
        icon: String = "",
        position: Int = 0,
        hidden: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.parentID = parentID
        self.slug = slug
        self.title = title
        self.icon = icon
        self.position = position
        self.hidden = hidden
    }
}

/// The whole menu as one read sees it: the compare-and-set `revision` every
/// CLI write sends back, the folders in pre-order (root, then each folder
/// followed by its children by position, the CLI's `list` order) and the
/// routes (automation id → folder id).
package struct InboxFolderTree: Equatable, Sendable {
    package let revision: Int64
    package let folders: [InboxFolder]
    package let routes: [Int64: Int64]

    package init(revision: Int64, folders: [InboxFolder], routes: [Int64: Int64] = [:]) {
        self.revision = revision
        self.folders = folders
        self.routes = routes
    }

    /// A database without the folder tables (or without their seed rows):
    /// the root alone, with id 0 and revision 0. Everything shows in it.
    package static let rootOnly = Self(
        revision: 0,
        folders: [InboxFolder(id: 0, kind: .root, parentID: nil, slug: "inbox", title: "Inbox")]
    )

    /// The root is always first (pre-order); `rootOnly` when none was read.
    package var root: InboxFolder { folders.first ?? Self.rootOnly.folders[0] }
    package var approvals: InboxFolder? { folders.first { $0.kind == .approvals } }

    package func folder(_ id: Int64) -> InboxFolder? { folders.first { $0.id == id } }

    /// A folder whose own `hidden` or any ancestor's is set leaves the menu
    /// and the badge. An unknown id is not visible.
    package func isVisible(_ id: Int64) -> Bool {
        var current = folder(id)
        var steps = 0
        while let folder = current, steps <= folders.count {
            if folder.hidden { return false }
            guard let parent = folder.parentID else { return true }
            current = self.folder(parent)
            steps += 1
        }
        return false
    }
}

/// The Inbox menu's reads (spec "The model"). Each tolerates an older
/// database without the folder tables (`ActionStripViewModel.isMissingTable`):
/// a root-only tree in which every artifact shows. Any other error throws.
package enum InboxFolderQueries {
    /// The tree in pre-order. No root row (tables without their seeds) reads
    /// as `InboxFolderTree.rootOnly`; a folder not reachable from the root
    /// (impossible under the foreign keys) is left out.
    package static func tree(_ db: Database) throws -> InboxFolderTree {
        do {
            let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM inbox_folder_state WHERE id = 1") ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, kind, parent_id, slug, title, icon, position, hidden
                FROM inbox_folders ORDER BY position, id
                """)
            let folders = rows.compactMap { row -> InboxFolder? in
                guard let kind = InboxFolder.Kind(rawValue: row["kind"] ?? "") else { return nil }
                return InboxFolder(
                    id: row["id"], kind: kind, parentID: row["parent_id"], slug: row["slug"],
                    title: row["title"], icon: row["icon"], position: row["position"], hidden: row["hidden"]
                )
            }
            guard let root = folders.first(where: { $0.kind == .root }) else { return .rootOnly }
            let children = Dictionary(grouping: folders.filter { $0.parentID != nil }) { $0.parentID ?? 0 }
            var ordered: [InboxFolder] = []
            var seen: Set<Int64> = []
            func visit(_ folder: InboxFolder) {
                guard seen.insert(folder.id).inserted else { return }
                ordered.append(folder)
                // `rows` is already by position, id: grouping keeps that order.
                for child in children[folder.id] ?? [] { visit(child) }
            }
            visit(root)
            let routeRows = try Row.fetchAll(db, sql: "SELECT automation_id, folder_id FROM inbox_folder_routes")
            var routes: [Int64: Int64] = [:]
            for row in routeRows { routes[row["automation_id"]] = row["folder_id"] }
            return InboxFolderTree(revision: revision, folders: ordered, routes: routes)
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return .rootOnly
        }
    }

    /// The open artifacts (inbox outputs neither done nor dismissed, read or
    /// not) of every folder of `tree`, each list in the Inbox order
    /// (`changed_at` newest first, `AutomationQueries.fetchInboxOutputs`).
    /// The folder is the view `inbox_artifact_folders` (explicit folder ??
    /// route ?? root), the same view the Go CLI reads; one the tree does not
    /// hold (no seed rows, or no view on an older database) shows in the root.
    package static func artifactsByFolder(_ db: Database, tree: InboxFolderTree) throws -> [Int64: [AutomationOutputCard]] {
        let cards: [AutomationOutputCard]
        do {
            cards = try AutomationQueries.fetchInboxOutputs(db, includeRead: true)
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return [:]
        }
        guard !cards.isEmpty else { return [:] }
        let placed = try artifactFolders(db)
        let known = Set(tree.folders.map(\.id))
        var out: [Int64: [AutomationOutputCard]] = [:]
        for card in cards {
            let folder = placed[card.id].flatMap { known.contains($0) ? $0 : nil } ?? tree.root.id
            out[folder, default: []].append(card)
        }
        return out
    }

    /// One folder's open artifacts, in the Inbox order.
    package static func artifacts(_ db: Database, folderID: Int64) throws -> [AutomationOutputCard] {
        let tree = try tree(db)
        return try artifactsByFolder(db, tree: tree)[folderID] ?? []
    }

    /// output id → folder id, from the view. A missing view (an older
    /// database) places nothing.
    private static func artifactFolders(_ db: Database) throws -> [Int64: Int64] {
        do {
            let rows = try Row.fetchAll(db, sql: "SELECT output_id, folder_id FROM inbox_artifact_folders")
            var out: [Int64: Int64] = [:]
            for row in rows {
                if let folder = row["folder_id"] as Int64? { out[row["output_id"]] = folder }
            }
            return out
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return [:]
        }
    }

    /// The Messages legacy entry stands in for Waiting for me (spec "Waiting
    /// for me") until the built-in's first successful run and after a failed
    /// one: true unless its latest finished run succeeded. No row for the
    /// built-in, or an older database, stands in.
    package static func messagesStandIn(_ db: Database) throws -> Bool {
        do {
            let status = try String.fetchOne(db, sql: """
                SELECT r.status FROM automation_runs r JOIN automations a ON a.id = r.automation_id
                WHERE a.builtin_id = ? AND r.status NOT IN ('queued', 'running', 'waiting')
                ORDER BY r.id DESC LIMIT 1
                """, arguments: [waitingForMeBuiltinID])
            return status != "succeeded"
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return true
        }
    }

    /// The `waiting-for-me` built-in's id (`builtin.Entry`, Go).
    package static let waitingForMeBuiltinID = "waiting-for-me"
}
