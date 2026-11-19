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
        ["watchman", "backtest"],
        ["watchman", "learn"],
        ["workbench", "review", "lessons", "propose"],
        ["workbench", "review", "overview"],
        ["workbench", "session", "start"],
        ["workbench", "spec-review", "run"],
        ["workbench", "spec-review", "start"]
    ]

    /// The root's persistent flags that take a value (`cmd/root.go`:
    /// `--workspace`, `--config`, `--provider`), plus `--db`, which the brief's
    /// launchers put first. Their value is consumed wherever the flag stands,
    /// so it is never read as a command word (`--workspace digest sync`).
    /// `ModelCommandsTests.testGlobalValueFlagsMatchTheGoRoot` keeps the root's
    /// string flags in this set.
    package static let globalValueFlags: Set<String> = ["--workspace", "--config", "--provider", "--db"]

    /// The model command `argv` runs, as its space-joined path ("digest
    /// generate"), or nil. A path is a prefix (`meeting-prep` covers every
    /// `meeting-prep …` command, as the Go list means it). Flags are skipped
    /// wherever they stand, as cobra skips them: a global value flag
    /// (`globalValueFlags`) with its value, `--name=value` alone, and any other
    /// `--flag`, after which a token that is not the next path word is taken as
    /// that flag's value (`jira --account 3 boards analyze`). `--` ends the
    /// command words.
    package static func match(_ argv: [String]) -> String? {
        paths.first { matches($0, argv) }.map { $0.joined(separator: " ") }
    }

    private static func matches(_ path: [String], _ argv: [String]) -> Bool {
        var next = 0
        var afterFlag = false
        var index = argv.startIndex
        while index < argv.endIndex, next < path.count {
            let token = argv[index]
            index += 1
            if token == "--" { return false }
            if globalValueFlags.contains(token) {
                index += 1 // its value
                afterFlag = false
                continue
            }
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
