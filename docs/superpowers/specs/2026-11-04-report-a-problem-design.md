# Report a Problem — design (target #1527)

**Status:** spec, not implemented. **Board:** #1527. **Mockups:** [docs/design/mockups/report-a-problem/](../../design/mockups/report-a-problem/README.md).

## Goal

Watchtower has no telemetry and no crash reporting service (ask #996). The only way to hear about a problem on a stranger's Mac is a report the user files. Help → **Report a Problem…** lets them describe it in their own words and opens the GitHub bug form already filled with everything the app can work out itself. The app sends nothing: the user sees every character before it leaves, and submits it on GitHub themselves.

## Context (recon, 2026-11-04)

- **Help menu.** `HelpCommands` in `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`CommandGroup(after: .help)`: Ask Watchtower… ⌘/, Watchtower User Guide, Keyboard Shortcuts). About is `AboutPanel.show()` (`Sources/App/AboutPanel.swift`, `WatchtowerApp.swift`). Settings → System is `Views/Settings/SystemSettings.swift` (sections Workspace, AI, Workbench, Sync, Logs (**Open Logs**), Update, Usage).
- **Links.** `ReleaseLinks.repository` (`https://github.com/aiwatchtowers/watchtower`) and `GuideLinks` in WatchtowerCore; external URLs open with `NSWorkspace.shared.open` (only `watchtower-nav://` links go through `AppState.openNavLink`).
- **Version and flavor.** Go `cmd.Version`/`Commit`/`BuildDate`/`BuildFlavor` (ldflags from `scripts/build-app.sh`), printed by `watchtower version`. The app has `CFBundleShortVersionString` and `WTBuildFlavor` in Info.plist (read by `UpdateService` and `HubIdentity`).
- **State the Desktop can read today, scattered:** provider via `ConfigService().aiProvider`; per-service account counts and states via `ConnectionSummary` over six account view models; feature states via `watchtower features list --json`; daemon via `DaemonManager` (pid, `last_sync.json` mtime); readiness via `ReadinessCenter`/`FeatureReadiness`; pipeline runs via `PipelineRunQueries`. No one place has all of it, and several (Quick Connections, policy, schema version, crash log) are Go-only or file-only.
- **Existing summaries are not safe to share.** `watchtower status` prints the workspace name, team domains and the database path; `pipeline_runs.error_msg`, account status text and backfill `last_error` hold the *full* provider error text (FILES-01 lets them, because only the owner reads them).
- **Logs.** `watchtower.log` (sync log, rotated), `daemon.log` (daemon stderr: Go panics, pid-file warnings; follows the same rotation), `sessions.log` (20 MiB), `dblock.jsonl` (lock metrics, call sites). Settings → System → Logs shows the first two. FILES-01 keeps synced names and text out of them, but they still carry account short names and source ids (`channel=<acct>:<id>`, `user=<acct>:<id>`) — an account short name is often the company's name, and the bug form asks people not to paste ids. Rotated copies written before FILES-01 (2026-10-25) can still hold text until Stage C deletes them.
- **No diagnostics feature exists** (no "copy debug info", no `watchtower diagnostics`).
- **CLI calls.** `CLIRunnerProtocol.run(args:timeout:)` (WatchtowerCore) runs the bundled CLI with a timeout and terminates the child.
- **GitHub prefill.** Issue-form fields are prefilled by `?template=bug_report.yml&<id>=<value>`; the field `id` is the key (GitHub's form-schema doc). The docs promise this for text fields (`input`, `textarea`); dropdowns are known to accept an exact option label; checkboxes cannot be prefilled. Past the server's limit GitHub answers `414 URI Too Long` (no number documented; ~8 KB in practice). `bug_report.yml` ids: `version`, `macos` (input), `chip`, `provider` (dropdown), `sources` (checkboxes), `steps`, `expected`, `actual`, `logs` (textarea, `render: text`).

## Design

### One source: `watchtower diagnostics`

A new read-only command `watchtower diagnostics [--json]` composes the summary; the Desktop shows its `text` verbatim and never builds a line of its own. Go is the one source because it already owns every input (config, provider resolution, features registry, every account table, Quick Connections, policy, daemon pid, `pipeline_runs`, goose version, log files) and the error classifiers; a Swift copy would be a Go↔Swift dual path over a dozen readers. A user without the app window (or a script) gets the same text from the terminal, and the guide can point at it.

`--json` pinned keys: `text` (the block below), `version` (`cmd.Version`), `macos` (`macOS 15.5`, from `sysctl kern.osproductversion`), `chip` (the form's option: `Apple M1`…`Apple M5` from `machdep.cpu.brand_string` with Pro/Max/Ultra dropped, else `Other`), `provider` (the form's option: `Claude Code`/`Codex`/`Ollama (or another local server)`/`Not set up yet`), `sources` (form labels of connected kinds). Plain output prints `text`.

The text, one fact per line, kinds, counts, states and classes only:

```
Watchtower <version> (commit <sha>, flavor: <flavor>) · app <bundle version>
macOS <x.y> · <chip>
AI: <provider> · reserve <provider>, automatic|off
Features on: <feature ids>
Sources: <Kind> <n> ok|<k> needs sign-in|<k> error|purged … ; Quick Connections <n>; iPhone companion on|off
Daemon: running|stopped · last cycle <age> ago, done|error|running
Last 24 h: <pipeline> <error class> ×<n> …  (none)
Crash log: last panic <date> in <pkg.Func> | no panic since <date>
Logs: watchtower.log <size> · daemon.log <size> (not attached)
Database: schema <goose version> · <size> · managed by organization: yes|no
```

- The app version line: the Desktop passes `--app-version <CFBundleShortVersionString>` and the CLI prints it, so a mismatched CLI/app pair is visible and the line is still built in Go.
- Error class = a closed list `auth`, `rate_limit`, `quota`, `timeout`, `network`, `not_found`, `other`, from the existing provider classifiers (`ai`/`codex` `classifyError`, Jira/Ollama/Linear auth errors) over `pipeline_runs.error_msg`; the text itself never reaches the output.
- Crash log: only the tail (≤ 256 KB) of `daemon.log` is read; the line names the panic time and the first `watchtower/…` frame's function — code, not data. The panic message is never printed.
- Logs and `dblock.jsonl`/`sessions.log` are stat'ed only, never read (except the crash tail above).
- The database is opened read-only (`query_only`, no migrations). A pending migration prints `schema <n> (behind)`.
- Never printed: workspace name, account/team/site names and domains, emails, ids, channel/project/space names, Quick Connection and automation names, paths, model output, error text, log lines.

### The sheet

Help → **Report a Problem…** (after Watchtower User Guide) and **Report a Problem…** in Settings → System → Logs open one sheet (a one-field form — the style guide's sheet case). Layout (see mockups): title, one-line intro, **What happened?** field, the diagnostics block as it will be sent (monospaced, selectable, in a card), the public-issue note, and Cancel · **Save Diagnostics…** · **Open GitHub Issue** (the one prominent action).

States (`ReportProblemModel` in WatchtowerCore, `@Observable`, view owns no logic):

| State | Diagnostics block | Buttons |
|---|---|---|
| collecting | progress + "Collecting diagnostics…" | Save and Open disabled |
| ready, empty text | the text | Open disabled, "Describe the problem to continue." |
| ready, text | the text | all enabled |
| failed | warning + reason, partial line `Watchtower app <bundle version>`, **Retry** | enabled (report carries the app version only) |
| opened via clipboard | unchanged | notice + **Done** |
| browser failed | unchanged | notice + **Done** |
| save failed | unchanged | inline notice, buttons stay |

On a plain successful open the sheet closes. The field is capped at 2 000 characters.

### The link

`ReportProblemLink.make(diagnostics:userText:)` (pure, WatchtowerCore) builds `ReleaseLinks.repository/issues/new` with `template=bug_report.yml`, `title=<first line of the user text, ≤ 80 chars>`, `version`, `macos`, `chip`, `provider`, `actual=<user text>`, `logs=<diagnostics text>`. Steps and expected stay for the user on GitHub (the form requires them; the app cannot know them). `sources` is not a URL field (checkboxes); the kinds are in the `Sources:` line.

Budget: the encoded URL is at most 6 000 characters. Over it, `logs` becomes `Diagnostics are on the clipboard — paste them here.`, the diagnostics go to the clipboard and the sheet shows the clipboard notice. With the 2 000-character cap the shortened URL always fits (a test proves it at the cap with worst-case encoding).

**Save Diagnostics…** — `NSSavePanel`, default `watchtower-diagnostics-<yyyy-MM-dd>.txt`, writes what happened + the diagnostics text, atomically.

## UI strings (in `ReportProblemCopy`, pinned by `ReportProblemCopyTests`)

Title `Report a Problem`; menu items `Report a Problem…`; intro `Tell us what went wrong. Watchtower sends nothing itself: you review everything below and submit it on GitHub.`; `What happened?`; placeholder `What you did, what you expected, what you saw instead.`; `Describe the problem to continue.`; `Diagnostics that will be included`; `Kinds, counts and states only — no names, ids, message text or log lines.`; `Collecting diagnostics…`; failure `Could not collect diagnostics: <reason>. The report will carry the app version only.` with reasons `the watchtower command did not answer in 10 seconds` / `the watchtower command is missing` / `the watchtower command failed (exit <n>)` / `its answer could not be read`; `Retry`; `GitHub issues are public. Check the text before you submit.`; `Cancel`; `Save Diagnostics…`; `Open GitHub Issue`; `Done`; `The diagnostics did not fit in the link. They are on the clipboard — paste them into Logs on GitHub.`; `Could not open your browser. The issue link is on the clipboard — paste it into a browser.`; `Could not save the file: <localized reason>`; logs placeholder `Diagnostics are on the clipboard — paste them here.`

Colors only through `Tone` (`Tone.warning` for failures, `Tone.success` for the clipboard notice); kit buttons, `.card()` groups, no row separators, no stock form chrome.

## Failure modes

| Path | Behaviour | Test |
|---|---|---|
| CLI missing (`CLIBinaryStore` finds none) | failed state, reason "missing", Open still works with the app version | `ReportProblemModelTests.testMissingCLI` (fake runner throws launch error) |
| CLI times out (10 s) | runner terminates the child; failed + Retry | `testTimeoutShowsRetry` (fake runner throws `nonZeroExit(-1)`) |
| CLI exits non-zero / bad JSON | failed with exit code / "could not be read" | `testNonZeroExit`, `testUndecodableJSON` |
| Database locked or missing | CLI still prints every non-DB line, `Database: unavailable` | Go `TestDiagnostics_NoDatabase` |
| Log file missing / unreadable | `watchtower.log missing` / `unreadable`; never fails the command | Go `TestDiagnostics_LogMissing`, `TestDiagnostics_LogUnreadable` |
| Huge log | only stat'ed; `daemon.log` tail capped at 256 KB | Go `TestDiagnostics_HugeCrashLogReadsTail` |
| URL too long | clipboard fallback + notice | `ReportProblemLinkTests.testOverBudgetMovesDiagnosticsToClipboard`, `testCapAlwaysFits` |
| Browser does not open (`NSWorkspace.open` false) | link to clipboard + notice, sheet stays | `testBrowserFailureCopiesLink` (injected opener) |
| User closes mid-way (Cancel/Esc while collecting) | task cancelled, child terminated by the runner, nothing written, text discarded | `testCancelWhileCollectingTerminates` |
| Save fails | inline notice with the reason, sheet stays, nothing partial left (atomic write) | `testSaveFailureShowsReason` (injected writer) |

**Writers.** None of this data has a writer: the command and the sheet only read. The only writes are the user-chosen file and the general pasteboard, each written once per user action; no other writer exists.

## Privacy

- What leaves the Mac: only what the user sees in the sheet and submits on GitHub themselves (or saves and attaches). No network call by the app; `NSWorkspace.open` hands a URL to the browser.
- The diagnostics carry kinds, counts, states, error classes, sizes, versions and dates; never names, domains, emails, ids, paths, message/mail text, AI output, error text or log lines (see the never-printed list).
- **Guard (proposed DIAG-01):** `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText` seeds a database and files with `logcanary.Marker` canaries in every name and text column the command reads around (workspace name, account names, team domains, emails, channel/space/project names, Quick Connection and automation names, `pipeline_runs.error_msg`, account status text, `daemon.log` panic message, `watchtower.log` lines) and asserts neither the text nor the JSON contains the marker, and that no `/Users/` path or `<acct>:<id>` shape appears. Swift `ReportProblemLinkTests.testLinkCarriesOnlyCLITextAndUserText`.
- The user's own text is theirs: the sheet says the issue is public; the app does not scan it.

## Decisions

| # | Decision | Source |
|---|---|---|
| 1 | No telemetry, no crash service; the report is user-initiated and the app sends nothing | ask #996 |
| 2 | Build Report a Problem now | ask #1023 |
| 3 | Go `watchtower diagnostics` is the one source; the Desktop shows its text verbatim (no Swift composer, no dual path) | decided by agent |
| 4 | No log lines at all, raw or scrubbed: logs keep account short names and ids, and old rotations may predate FILES-01; problems are reported as pipeline error classes and counts instead | decided by agent |
| 5 | Crash line names the panic time and first `watchtower/…` frame only | decided by agent |
| 6 | One user field (what happened → `actual`, first line → `title`); steps/expected are left to the GitHub form | decided by agent |
| 7 | URL budget 6 000 chars, 2 000-char field cap, clipboard fallback for the diagnostics | decided by agent |
| 8 | On CLI failure the report still opens, carrying the app version only; the Desktop does not derive macOS/chip itself (would duplicate Go) | decided by agent |
| 9 | Diagnostics open the database read-only and never migrate | decided by agent |
| 10 | Entry points: Help menu + Settings → System → Logs; no About link, no toolbar button | decided by agent |
| 11 | No draft kept when the sheet closes | decided by agent |
| 12 | Screenshots/videos are not part of the report (the form's own hint covers them) | conversation |

**Contracts touched that the owner has not approved:**
- New inventory entry **DIAG-01** ("diagnostics carry kinds, counts, states and classes only") with its guard — new contract, needs approval.
- **FILES-01** is not changed, but decision 4 relies on its limits (logs still carry `<acct>:<id>`); worth the owner's eye.
- A new CLI command with pinned `--json` keys (`text`, `version`, `macos`, `chip`, `provider`, `sources`) — a new Go↔Desktop contract, recorded in a new feature note `docs/features/report-a-problem.md`.

## Mockups

Real SwiftUI shots from `DesignShotCatalog` (`ReportProblemShotFixtures`, `Tests/DesignShots/DesignShotFixtures+ReportProblem.swift`, design-only, sample data only), light and dark, in [docs/design/mockups/report-a-problem/](../../design/mockups/report-a-problem/README.md): `report-problem-collecting` (loading/busy), `-empty`, `-filled`, `-failed` (error with Retry), `-clipboard`, `-browserFailed`, `-saveFailed`, `-filled-narrow` (360 pt). Re-render: `make desktop-shots DESKTOP_SHOTS=<dir>` or `swift test --filter DesignShotsTests/testReportProblemShotsRender` with `DESKTOP_SHOTS_DIR`. The implementation replaces the fixture's local copy with `ReportProblemCopy`.

## Out of scope / v1 limits

- No upload of logs, screenshots or files by the app; the user attaches a saved `.txt` by hand.
- No feature-request or Discussions entry (the form's `config.yml` already links Discussions).
- No in-app issue search or duplicate detection; no GitHub sign-in.
- Steps and expected behaviour are typed on GitHub, not in the sheet.
- The iPhone app has no Report a Problem in v1.
- Dropdown prefill (`chip`, `provider`) relies on GitHub accepting the exact option label; if GitHub ignores it the user picks it, the values are in the diagnostics text anyway.

## Docs

- Guide: `docs/guide/troubleshooting/README.md` gains "Report a problem" (Help → Report a Problem…, what is included, `watchtower diagnostics` from the terminal); `.github/ISSUE_TEMPLATE/bug_report.yml`'s `version`/`logs` descriptions mention `watchtower diagnostics`.
- Feature note `docs/features/report-a-problem.md` + CLAUDE.md index line; inventory file for DIAG-01 after approval.
