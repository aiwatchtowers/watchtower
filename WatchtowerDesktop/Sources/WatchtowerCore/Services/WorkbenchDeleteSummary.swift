import Foundation
import GRDB

/// What a workbench delete removes, for the confirmation dialog (spec §6.1:
/// "confirmation lists what is removed, incl. the folder cleanup").
/// `legacy` is `integrate status`'s flag for a folder set up before the
/// Workbench rename: Go `devpack.RemoveWorkbench` removes that setup's
/// skill and MCP registration too, so the confirmation names them.
package struct WorkbenchDeleteSummary: Equatable {
    package let name: String
    package let folder: String
    package let targets: Int
    package let asks: Int
    package let comments: Int
    /// The AI questions asked about the folder's code (Questions tab).
    package let codeQuestions: Int
    package let legacy: Bool

    package init(
        name: String,
        folder: String,
        targets: Int,
        asks: Int,
        comments: Int,
        codeQuestions: Int = 0,
        legacy: Bool = false
    ) {
        self.name = name
        self.folder = folder
        self.targets = targets
        self.asks = asks
        self.comments = comments
        self.codeQuestions = codeQuestions
        self.legacy = legacy
    }

    package static func fetch(_ db: Database, project: Workbench, legacy: Bool) throws -> Self {
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
            codeQuestions: try CodeQuestionList.count(db, workbenchID: project.id),
            legacy: legacy
        )
    }

    package var title: String { "Delete workbench “\(name)”?" }

    package var message: String {
        """
        Watchtower removes the board: \(Self.plural(targets, "target")), \
        \(Self.plural(asks, "ask")) and \(Self.plural(comments, "comment")).\(questionsSentence) \
        The files in the folder themselves stay; Watchtower's own \
        copies of images attached to targets are deleted.

        In \(folder) it removes what it installed: the \(WorkbenchNames.skill) skill, \
        the SessionStart hook in .claude/settings.local.json, the \(WorkbenchNames.mcpServer) \
        MCP registration, Codex's copy of the skill in .agents/skills and the \
        Watchtower hooks Codex imported into .codex, and the .git/info/exclude \
        lines it added.\(legacySentence) A skill you edited is kept, and so is an exclude line \
        whose file still exists. Nothing else in the folder is touched. Codex's \
        hook trust in ~/.codex/config.toml stays: every workbench shares it.

        The workbench's terminal session is closed first.
        """
    }

    private var legacySentence: String {
        legacy
            ? " The folder was set up before the Workbench rename, so the pre-rename "
                + "\(WorkbenchNames.preRename) skill and \(WorkbenchNames.preRename) MCP registration go too."
            : ""
    }

    private var questionsSentence: String {
        codeQuestions == 0 ? "" : " Its \(Self.plural(codeQuestions, "question")) about the code go too."
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
