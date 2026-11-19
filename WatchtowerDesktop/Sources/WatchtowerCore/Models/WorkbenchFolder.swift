import Foundation
import GRDB

/// One `workbench_folders` row (00209, multi-folder workbench): a folder on a
/// workbench. All folders are equal; the home folder is the one the
/// workbench was opened with (`projects.folder_path`). A removed folder keeps
/// its row (`removedAt` set) so sessions and targets can still name it. The
/// Go CLI is the only writer (`workbench folder …`); the Desktop reads it.
package struct WorkbenchFolder: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
    package let id: Int64
    package let workbenchID: Int64
    /// Absolute and symlink-resolved, as Go stores it.
    package let folderPath: String
    package let position: Int
    /// `owner` or `agent_suggestion`.
    package let addedBy: String
    /// nil while the folder is on the bench.
    package let removedAt: String?
    /// The folder's short name, unique among the bench's live folders: what
    /// every label, doc path and `start_session(folder)` uses.
    package var name: String

    package enum CodingKeys: String, CodingKey {
        case id, position, name
        case workbenchID = "workbench_id"
        case folderPath = "folder_path"
        case addedBy = "added_by"
        case removedAt = "removed_at"
    }

    package init(
        id: Int64,
        workbenchID: Int64,
        folderPath: String,
        position: Int,
        addedBy: String = "owner",
        removedAt: String? = nil,
        name: String
    ) {
        self.id = id
        self.workbenchID = workbenchID
        self.folderPath = folderPath
        self.position = position
        self.addedBy = addedBy
        self.removedAt = removedAt
        self.name = name
    }

    package var isRemoved: Bool { removedAt != nil }

    package var url: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
}

/// A workbench's folders as one read gives them: every row in position
/// order (removed ones included) and which one is home. `folderID` nil
/// everywhere in the schema (`targets`, `owner_asks.doc_folder_id`) means
/// the home folder.
package struct BenchFolders: Equatable, Sendable {
    package let folders: [WorkbenchFolder]
    /// The home folder's row id (Go `db.HomeFolder`); nil only for a
    /// workbench with no folder row at all.
    package let homeID: Int64?

    package init(folders: [WorkbenchFolder] = [], homeID: Int64? = nil) {
        self.folders = folders
        self.homeID = homeID
    }

    /// The folders on the bench, in position order.
    package var live: [WorkbenchFolder] { folders.filter { !$0.isRemoved } }

    package var home: WorkbenchFolder? { homeID.flatMap { id in folders.first { $0.id == id } } }

    /// The folder a stored folder id names: nil → home. nil when the id names
    /// no row of this bench.
    package func folder(_ id: Int64?) -> WorkbenchFolder? {
        guard let id else { return home }
        return folders.first { $0.id == id }
    }

    /// Spec §6.11: a document path as asks and search show it —
    /// `<folder>/<rel>` when the bench has more than one live folder, `<rel>`
    /// otherwise (and when the folder is unknown).
    package func displayPath(_ relativePath: String, folderID: Int64?) -> String {
        guard live.count > 1, let folder = folder(folderID) else { return relativePath }
        return "\(folder.name)/\(relativePath)"
    }
}
