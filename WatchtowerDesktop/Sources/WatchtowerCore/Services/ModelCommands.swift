import Foundation

/// The CLI command paths that call a model: the Desktop's copy of the shared
/// list `internal/aiconsent/testdata/model_commands.json` (Go
/// `TestModelCommands_ExistInCLI` keeps its paths real; the list is
/// hand-kept, so a new model-running command goes into the JSON and here).
/// `ModelCommandsTests.testBundledListMatchesGoFixture` renders `paths` in the
/// fixture's layout and compares the bytes, so the two cannot drift.
///
/// The list is compiled in rather than shipped as a resource: `WatchtowerCore`
/// has no resource bundle, and SwiftPM's `Bundle.module` does not find one in
/// the packaged `.app` (see `AppBundle`), so a missing file would fail the
/// first CLI call of every install.
///
/// `CLIRunner` refuses a matching argv on its generic entries
/// (`CLIRunnerError.modelCommandNeedsOrigin`): a model command launches only
/// through `runModel(args:origin:…)`, which names who started it.
package enum ModelCommands {
    package static let paths: [[String]] = [
        ["ai", "query"],
        ["ai", "session"],
        ["ai", "test"],
        ["ask"],
        ["automations", "dry-run"],
        ["automations", "preview"],
        ["briefing", "generate"],
        ["catchup", "feedback"],
        ["catchup", "run"],
        ["chat", "title"],
        ["coach", "run"],
        ["day-plan", "generate"],
        ["dictate", "clean"],
        ["digest", "generate"],
        ["digest", "summary"],
        ["ideas", "mine"],
        ["inbox", "generate"],
        ["jira", "boards", "analyze"],
        ["jira", "fields", "discover"],
        ["jira", "fields", "map"],
        ["meeting-prep"],
        ["memory", "consolidate"],
        ["memory", "digest-compare"],
        ["people", "generate"],
        ["profile", "style-sample"],
        ["reaction-commands", "poll"],
        ["slack", "backfill"],
        ["targets", "ai-update"],
        ["targets", "extract"],
        ["targets", "generate"],
        ["targets", "next-step"],
        ["targets", "suggest-links"],
        ["terminal", "title"],
        ["tracks", "create"],
        ["tracks", "generate"],
        ["tracks", "scan"],
        ["tune"],
        ["workbench", "review", "lessons", "propose"],
        ["workbench", "review", "overview"],
        ["workbench", "session", "start"],
        ["workbench", "spec-review", "run"],
        ["workbench", "spec-review", "start"]
    ]

    /// The model command `argv` runs, as its space-joined path ("digest
    /// generate"), or nil. A path is a prefix (`meeting-prep` covers every
    /// `meeting-prep …` command, as the Go list means it). Flags are skipped
    /// wherever they stand, as cobra skips them: the leading `--config <path>`
    /// / `--db <path>`, and inner ones such as `jira --account 3 boards
    /// analyze`. A token after a `--flag` (no `=`) that is not the next path
    /// word is taken as that flag's value. `--` ends the command words.
    package static func match(_ argv: [String]) -> String? {
        paths.first { matches($0, argv) }.map { $0.joined(separator: " ") }
    }

    private static func matches(_ path: [String], _ argv: [String]) -> Bool {
        var next = 0
        var afterFlag = false
        for token in argv {
            if next == path.count { return true }
            if token == "--" { return false }
            if token.count > 1, token.hasPrefix("-") {
                afterFlag = !token.contains("=")
                continue
            }
            if token == path[next] {
                next += 1
                afterFlag = false
            } else if afterFlag {
                afterFlag = false
            } else {
                return false
            }
        }
        return next == path.count
    }
}
