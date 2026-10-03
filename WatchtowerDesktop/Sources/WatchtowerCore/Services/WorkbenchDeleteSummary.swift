import Foundation
import GRDB

/// What a workbench delete removes, for the confirmation dialog (spec §6.1:
/// "confirmation lists what is removed, incl. the folder cleanup").
/// `vocabulary` names the skill and MCP server the folder has: a folder set
/// up before the Workbench rename has the old ones (spec 2026-10-02 §5.5 —
/// the delete removes both vocabularies, Go `devpack.RemoveWorkbench`).
package struct WorkbenchDeleteSummary: Equatable {
    package let name: String
    package let folder: String
    package let targets: Int
    package let asks: Int
    package let comments: Int
    package let vocabulary: WorkbenchVocabulary

    package init(
        name: String,
        folder: String,
        targets: Int,
        asks: Int,
        comments: Int,
        vocabulary: WorkbenchVocabulary = .current
    ) {
        self.name = name
        self.folder = folder
        self.targets = targets
        self.asks = asks
        self.comments = comments
        self.vocabulary = vocabulary
    }

    package static func fetch(_ db: Database, project: Workbench, vocabulary: WorkbenchVocabulary) throws -> Self {
        func count(_ table: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE project_id = ?",
                             arguments: [project.id]) ?? 0
        }
        return Self(
            name: project.name,
            folder: project.folderPath,
            targets: try count("targets"),
            asks: try count("owner_asks"),
            comments: try count("project_comments"),
            vocabulary: vocabulary
        )
    }

    package var title: String { "Delete workbench “\(name)”?" }

    package var message: String {
        """
        Watchtower removes the board: \(Self.plural(targets, "target")), \
        \(Self.plural(asks, "ask")) and \(Self.plural(comments, "comment")). \
        The files in the folder themselves stay; Watchtower's own \
        copies of images attached to targets are deleted.

        In \(folder) it removes what it installed: the \(vocabulary.skillName) skill, \
        the SessionStart hook in .claude/settings.local.json, the \(vocabulary.mcpServerName) \
        MCP registration, and the .git/info/exclude lines it added. A skill you \
        edited is kept, and so is an exclude line whose file still exists. Nothing \
        else in the folder is touched.

        The workbench's terminal session is closed first.
        """
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
