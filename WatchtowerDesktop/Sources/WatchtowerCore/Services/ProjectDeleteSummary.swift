import Foundation
import GRDB

/// What a project delete removes, for the confirmation dialog (spec §6.1:
/// "confirmation lists what is removed, incl. the folder cleanup").
package struct ProjectDeleteSummary: Equatable {
    package let name: String
    package let folder: String
    package let targets: Int
    package let documents: Int
    package let comments: Int

    package init(name: String, folder: String, targets: Int, documents: Int, comments: Int) {
        self.name = name
        self.folder = folder
        self.targets = targets
        self.documents = documents
        self.comments = comments
    }

    package static func fetch(_ db: Database, project: Project) throws -> Self {
        func count(_ table: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE project_id = ?",
                             arguments: [project.id]) ?? 0
        }
        return Self(
            name: project.name,
            folder: project.folderPath,
            targets: try count("targets"),
            documents: try count("project_documents"),
            comments: try count("project_comments")
        )
    }

    package var title: String { "Delete project “\(name)”?" }

    package var message: String {
        """
        Watchtower removes the board: \(Self.plural(targets, "target")), \
        \(Self.plural(documents, "document")) and \(Self.plural(comments, "comment")). \
        The document files themselves stay in the folder.

        In \(folder) it removes what it installed: the watchtower-project skill, \
        the SessionStart hook in .claude/settings.local.json, the watchtower-project \
        MCP registration, and the .git/info/exclude lines it added. Nothing else \
        in the folder is touched.

        The project's terminal session is closed first.
        """
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
