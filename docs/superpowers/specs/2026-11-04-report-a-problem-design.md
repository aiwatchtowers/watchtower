# Report a Problem — design (target #1527)

**Status:** spec, not implemented. **Board:** #1527. **Mockups:** [`docs/design/mockups/report-a-problem/`](../../design/mockups/report-a-problem/README.md) on branch `feat/1527-report-problem` (listed with descriptions under Mockups below).

## Goal

Watchtower has no telemetry and no crash reporting service (ask #996). The only way to hear about a problem on a stranger's Mac is a report the user files. Help → **Report a Problem…** lets them describe it in their own words and opens the GitHub bug form already filled with everything the app can work out itself. The app sends nothing: the user sees every character before it leaves and submits it on GitHub themselves. Questions go to GitHub Discussions.

## Context (recon, 2026-11-04)

- **Help menu.** `HelpCommands` in `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`CommandGroup(after: .help)`: Ask Watchtower… ⌘/, Watchtower User Guide, Keyboard Shortcuts). About is `AboutPanel.show()`. Settings → System is `Views/Settings/SystemSettings.swift`; its Logs section has one button, **Open Logs**. `AppState.bringMainWindowForward(windows:activate:)` (`App/AppState+Automations.swift`) activates the app and calls `makeKeyAndOrderFront` on a visible or miniaturised main window, or opens one; both seams are injectable.
- **Links.** `ReleaseLinks.repository` (`https://github.com/aiwatchtowers/watchtower`) and `GuideLinks` in WatchtowerCore; external URLs open with `NSWorkspace.shared.open` (returns `false` when nothing opened).
- **Version and flavor.** Go `cmd.Version`/`Commit`/`BuildDate`/`BuildFlavor` (ldflags, `scripts/build-app.sh`; `BUILD_FLAVOR` is a free string), printed raw by `watchtower version`. The app has `CFBundleShortVersionString` and `WTBuildFlavor`; `HubIdentity.flavor(buildFlavor:)` treats empty or `dev` as the default build and anything else as a corporate build. The raw flavor string can name the company, so it is never printed — only `default`/`corp`.
- **State the Desktop can read today, scattered:** provider (`ConfigService().aiProvider`), per-service accounts (`ConnectionSummary` over six view models), features (`watchtower features list --json`), daemon (`DaemonManager`, `last_sync.json`), readiness (`ReadinessCenter`), pipeline runs (`PipelineRunQueries`). Quick Connections, policy, schema version and crash traces are Go-only or file-only.
- **Existing summaries are not safe to share.** `watchtower status` prints the workspace name, team domains and the database path. `pipeline_runs.error_msg`, account status text and backfill `last_error` hold the full provider error text (FILES-01 allows it: only the owner reads them).
- **No class classifier for stored errors.** `ai`/`codex` `classifyError(err, stderr)` work on a live process error; `chat.ClassifyClaudeError(msg)` maps Claude chat errors to chat codes. Nothing maps a stored `error_msg` of any pipeline to a closed class list.
- **Logs.** `watchtower.log` (sync log, `maxLogSize` 20 MiB, rotates to `watchtower.log.1`), `daemon.log`, `sessions.log` (20 MiB), `dblock.jsonl`. The detached daemon redirects its stderr into `watchtower.log` and follows it across rotations (`cmd/logfile.go` `newSyncLogWriter`/`followStderr`), so **Go panics land in `watchtower.log`/`.1`**; `daemon.log` keeps only what was written before the logger started, or all stderr if the redirect failed (older installs: an unbounded `daemon.log` from before the redirect). Log-package lines start with a `2006/01/02 15:04:05` timestamp; the Go runtime's crash output (`panic: …`, `fatal error: …`, then `goroutine N [running]:`) has none. The Settings → Logs "Crash Log" tab (`LogsSettings.LogFile.daemon`) and its caption ("Go runtime panics, …") are stale. FILES-01 keeps synced names and text out of the logs, but they still carry account short names and ids (`channel=<acct>:<id>`), and rotated copies from before 2026-10-25 can still hold text.
- **CLI start-up side effects.** `Execute()` (`cmd/root.go`) starts `sweepStaleTemp()` (removes Watchtower's expired temp files from the system temp dir) for every command; `rootCmd.PersistentPreRunE = ensureSchemaFormat` loads the config (fails the command on a broken one), may run `db.RunSchemaUpgrade` and rewrites the config's `db.schema_format`. Commands that must not do this set a no-op `PersistentPreRunE` (`ai`, `code`, `db compact`, `extract-pdf`, `ai routing-status`). `db.Open` migrates; `db.OpenExisting(path, busy)` opens `mode=rw` + `query_only`, never creates the file and runs no migration, but SQLite may create the `-wal`/`-shm` sidecars when none exist, and the open points the lock-metrics sink at `dblock.jsonl` (`lockmetrics.Configure`; `Configure("")` turns it off).
- **CLI calls.** `CLIRunnerProtocol.run(args:timeout:)` (WatchtowerCore) runs the bundled CLI and terminates the child on timeout.
- **No diagnostics feature exists.**
- **GitHub prefill.** `issues/new?template=bug_report.yml&<id>=<value>`; the field `id` is the prefill key (GitHub form-schema doc). Documented for text fields (`input`, `textarea`); dropdowns are known to take an exact option label; checkboxes cannot be prefilled. Past the server limit GitHub answers `414 URI Too Long` (no number documented; ~8 KB in practice). `bug_report.yml` ids: `version`, `macos` (input), `chip`, `provider` (dropdown), `sources` (checkboxes), `steps`, `expected`, `actual`, `logs` (textarea).

## Design

### One source: `watchtower diagnostics`

A new read-only command `watchtower diagnostics [--json] [--app-version <v>]` composes the summary; the Desktop shows its `text` verbatim and builds no line of its own. Go owns every input (config, provider resolution, features registry, every account table, Quick Connections, policy, daemon pid, `pipeline_runs`, goose version, log files) and the new error classifier; a Swift composer would be a Go↔Swift dual path over a dozen readers. A user without the app window gets the same text from the terminal.

**What it writes: nothing of Watchtower's.** Exactly:
- a no-op `PersistentPreRunE` (no `ensureSchemaFormat`: no schema upgrade, no config rewrite); the config is loaded by the command itself and its absence or a parse error is reported, not fatal;
- `Execute()` skips `sweepStaleTemp()` when the role is `cli:diagnostics`;
- the database is opened with `db.OpenExisting(path, 2 s)` (no migration, `query_only`) and `lockmetrics.Configure("")` right after, so no `dblock.jsonl` line;
- the one remaining effect: SQLite may create the database's `-wal`/`-shm` sidecars when no other process has them open (it removes them again on close). The database's content never changes.

Test `TestDiagnostics_WritesNothing`: a config with `db.schema_format` below current, a database with a pending migration, a stale temp file matching `fsutil.StaleTempPatterns`; after the run the config bytes, the database file's hash, the goose version and the stale temp file are unchanged, and the data directory listing equals the one before except for the database's own `-wal`/`-shm`.

`--json` pinned keys: `text`, `version`, `macos` (`macOS 15.5`, `sysctl kern.osproductversion`), `chip` (the form's option: `Apple M1`…`Apple M5` from `machdep.cpu.brand_string` with Pro/Max/Ultra dropped, else `Other`), `provider` (the form's option: `Claude Code`/`Codex`/`Ollama (or another local server)`/`Not set up yet`), `sources` (form labels of connected kinds), `flavor` (`default`|`corp`). Plain output prints `text`.

The text, one fact per line:

```
Watchtower <version> (commit <sha>, flavor: default|corp) · app <--app-version>
macOS <x.y> · <chip>
Config: ok | none (not set up) | unreadable (parse|permission|other)
AI: <provider> · reserve <provider>, automatic|off
Features on: <feature ids>
Sources: <Kind> <n> ok|<k> needs sign-in|<k> error|purged … ; Quick Connections <n>; iPhone companion on|off
Daemon: running|stopped · last cycle <age> ago, done|error|running
Recent errors (last 20):
  <yyyy-MM-dd HH:mmZ>  <phase>  <class>
Crash: none in the logs | <n> in the logs, last after <yyyy-MM-dd HH:mmZ> | time unknown, in <pkg.Func>
Logs: watchtower.log <size> · daemon.log <size> (not attached)
Database: schema <goose version> · <size> · managed by organization: yes|no
```

- **Recent errors.** The last 20 `pipeline_runs` rows with `status = 'error'` (time = `finished_at` in UTC, phase = `pipeline`, class), plus the last sync result in `last_sync.json` when it failed (phase `sync`). Never the text. No rows: `Recent errors: none`.
- **Error classes.** `diagnostics.ErrorClass(msg string) string` in a new `internal/diagnostics` package. Checks run in this fixed order on the lower-cased message; the first match wins:
  1. `cancelled` — `context canceled`
  2. `timeout` — `deadline exceeded`, `timed out`, `timeout`
  3. `rate_limit` — `rate limit`, `too many requests`, HTTP 429 in a status form (`status 429`, `http 429`, `status code: 429`, `429 too many`)
  4. `quota` — `usage limit`, `quota`, `insufficient credit`
  5. `auth` — `invalid_auth`, `token revoked`, `unauthorized`, `forbidden`, HTTP 401/403 in a status form
  6. `not_found` — HTTP 404 in a status form, `not_found`
  7. `network` — `connection refused`, `no such host`, `network is unreachable`, `connection reset`
  8. `parse` — `unmarshal`, `invalid character`, `unexpected end of json`
  9. `other` — everything else.

  A bare number never matches (a status form is `(status|http|status code)[ :=]*NNN` or `NNN <reason phrase>`). Unknown wordings fall to `other`. Table test `TestErrorClass`: each class, an id-like `…401…` that is not a status (→ `other`), and an order case (`timeout` + `401` → `timeout`).
- **Crash.** Streams, line by line, `watchtower.log.1`, `watchtower.log` and `daemon.log` (each scanned whole, under one 2 s budget for all three; current files are ≤ 20 MiB, an old unbounded `daemon.log` is the reason for the budget). A crash is a line that **starts** with `panic: ` or `fatal error: ` (no timestamp prefix, so a logged "panic:" inside a message never counts) followed within 5 lines by a `goroutine <n> [` header. Its time is the timestamp of the nearest preceding timestamped line in the same file ("after" that time); none → `time unknown`. Its place is the first following frame line starting with `watchtower/`. The newest is chosen by that time; ties and unknown times by file order — `watchtower.log` (newest), then `watchtower.log.1`, then `daemon.log`. Budget exhausted: the line ends with `(scan stopped after <N> MB)`. The panic message is never printed.
- **Never printed:** workspace name, account/team/site names and domains, emails, ids, channel/project/space names, Quick Connection and automation names, paths, raw flavor, model output, error text, log lines.
- **Partial output.** Each line is computed on its own; a failing reader prints `unknown (<reason>)` on its line and the command still exits 0.

| Line | No config (`Config: none (not set up)` or `unreadable (…)`) | Config ok, database missing or locked |
|---|---|---|
| Watchtower, macOS | printed | printed |
| AI, Features | `unknown (no config)` | printed |
| Sources | `unknown (no config)` | `unknown (no database)` / `unknown (database busy)` |
| Daemon | `unknown (no config)` (the pid file lives in the workspace) | printed |
| Recent errors | `unknown (no config)` | `unknown (no database)` / `unknown (database busy)` |
| Crash, Logs | `unknown (no config)` (the log files live in the workspace) | printed |
| Database | `unknown (no config)` | `unknown (no database)` / `unknown (database busy)` |

### The sheet

Help → **Report a Problem…** (after Watchtower User Guide) and **Report a Problem…** beside **Open Logs** in Settings → System → Logs open one sheet on the main window. Both entries always call `bringMainWindowForward()` first (activate + make key and order front, open the window if none), so the sheet never lands behind the Settings window or with no window at all. The style guide allows a sheet for a short one-field form.

Layout (see mockups): title, intro, **What happened?** field (≤ 2 000 characters), the diagnostics block exactly as it will be sent (monospaced, selectable, in a card), the public-issue note, a quiet **A question, not a problem? Ask in Discussions** link (`ReleaseLinks.repository/discussions`), and Cancel · **Save Diagnostics…** · **Open GitHub Issue** (the one prominent action). The buttons stack vertically when the sheet is narrow.

**Corporate build.** When `HubIdentity.bundleFlavor()` is `.corp`, the sheet shows the corp intro, no public note, no Discussions link and only Cancel · **Save Diagnostics…** (prominent). Nothing points at the public tracker.

States (`ReportProblemModel` in WatchtowerCore, `@Observable`, the view owns no logic):

| State | Diagnostics block | Buttons |
|---|---|---|
| collecting | progress + "Collecting diagnostics…" | Save and Open disabled |
| ready | the text | Open needs text (below) |
| failed | warning + reason, partial lines `Watchtower app <bundle version>` and `macOS <x.y>` (from `ProcessInfo`), **Retry** | Save enabled; Open needs text |
| opened | unchanged; "Opened in your browser…" notice | Cancel becomes **Done** |
| too long | unchanged; notice + **Copy Report** | **Done** |
| browser failed | unchanged; notice + **Copy Link** | **Done** |
| save failed | unchanged; inline notice | unchanged |

**Rule:** Open GitHub Issue is disabled while "What happened?" is empty (trimmed) in every state, failed included; Save Diagnostics… is enabled in every state but collecting. Test `testOpenNeedsTextInEveryState`.

**The sheet stays open after Open GitHub Issue** and keeps the text until **Done** or Cancel, so a GitHub error (sign-in, 414, network) loses nothing; pressing Open again rebuilds the link. Nothing is kept after the sheet closes.

### The link

`ReportProblemLink.make(report:)` (pure, WatchtowerCore) builds the GitHub link — `template=bug_report.yml`, `title=<first line of the user text, ≤ 80 characters>`, `version`, `macos`, `chip`, `provider`, `actual=<user text>`, `logs=<diagnostics text>`. Steps and expected are not separate fields (see Decisions); `sources` is not a URL field (checkboxes), the kinds are in the `Sources:` line. On a failed collection the link carries `version` (bundle) and `macos` (`ProcessInfo`) only; chip and provider are left for the user.

**Budget, by encoded length.** The limit applies to the final percent-encoded URL: 6 000 characters. One Cyrillic character costs 6 encoded characters, a CJK one 9, so a character cap alone does not fit. Steps, in order, stopping at the first that fits:
1. Full link.
2. `logs` replaced by `Paste the report from Watchtower here.`
3. `actual` also cut at a character boundary to what still fits, ending with `… (full text in the pasted report)`.

From step 2 on, the sheet shows the "too long" notice with **Copy Report** (user text + diagnostics). Tests `ReportProblemLinkTests`: ASCII, Cyrillic and CJK texts at the 2 000 cap each produce a link within budget; step 3 never splits a character or a percent escape; a short text yields the full link.

**Clipboard rule.** The app writes the clipboard only when the user presses a Copy button — never on its own. **Copy Report** writes the report, **Copy Link** writes the link; each press replaces the previous item and the notice says what was copied ("Report copied." / "Link copied."). Test `testClipboardWrittenOnlyByCopyButtons` (injected pasteboard: opening, failing to open and saving write nothing).

**Save Diagnostics…** — `NSSavePanel`, default `watchtower-diagnostics-<yyyy-MM-dd>.txt`, writes the report (user text, if any, + diagnostics), atomically.

## UI strings (in `ReportProblemCopy`, pinned by `ReportProblemCopyTests`)

| Key | Text |
|---|---|
| menu, title | `Report a Problem…`, `Report a Problem` |
| intro | `Tell us what went wrong. Watchtower sends nothing itself: you review everything below and submit it on GitHub yourself.` |
| corp intro | `This is your organization's build. Save the diagnostics and send the file to your IT team.` |
| field | `What happened?` / placeholder `What you did, what you expected, what you saw instead.` / `Describe the problem to continue.` |
| block | `Diagnostics that will be included` / `Kinds, counts, states and error classes only — no names, ids, message text or log lines.` |
| loading | `Collecting diagnostics…` |
| failed | `Could not collect diagnostics: <reason>. The report will carry the app and macOS versions only.`; reasons `the watchtower command did not answer in 10 seconds`, `the watchtower command is missing`, `the watchtower command failed (exit <n>)`, `its answer could not be read`; `Retry` |
| notes | `GitHub issues are public. Check the text before you submit.` / `A question, not a problem? Ask in Discussions` |
| buttons | `Cancel`, `Done`, `Save Diagnostics…`, `Open GitHub Issue`, `Copy Report`, `Copy Link`; Settings: `Open Logs` (existing), `Report a Problem…` |
| results | `Opened in your browser. Finish the issue there; this window keeps your text until you press Done.` / `The report did not fit in the link. Copy it and paste it into Logs on GitHub.` / `Report copied.` / `Link copied.` |
| errors | `Could not open your browser. Copy the link and paste it into a browser.` / `Could not save the file: <localized reason>` |
| link placeholders | `Paste the report from Watchtower here.` / `… (full text in the pasted report)` |

Colors only through `Tone` (`Tone.warning` for failures and the too-long notice, `Tone.success` for opened); kit buttons, `.card()` groups, `SettingsSection` for the Settings entry, no row separators, no stock form chrome.

## Failure modes

| Path | Behaviour | Test |
|---|---|---|
| CLI missing | failed, reason "missing"; link carries app + macOS versions | `ReportProblemModelTests.testMissingCLI` |
| CLI times out (10 s) | runner terminates the child; failed + Retry | `testTimeoutShowsRetry` |
| CLI exits non-zero / bad JSON | failed with the exit code / "could not be read" | `testNonZeroExit`, `testUndecodableJSON` |
| Link in failed state | `version` + `macos` only, no `chip`/`provider`/diagnostics | `ReportProblemLinkTests.testFailedStateLink` |
| Config missing / broken | exit 0; `Config:` says which; lines per the table above | Go `TestDiagnostics_NoConfig`, `TestDiagnostics_BrokenConfig` |
| Database missing or locked | lines per the table above | Go `TestDiagnostics_NoDatabase`, `TestDiagnostics_LockedDatabase` |
| Log file missing / unreadable | `Logs:` says `missing` / `unreadable` for that file; the crash scan skips it | Go `TestDiagnostics_LogMissing`, `TestDiagnostics_LogUnreadable` |
| Large log | whole files streamed, 2 s budget, `(scan stopped after <N> MB)` when hit | Go `TestDiagnostics_PanicDeeperThan256KB` (panic at the start of a 5 MB file is found), `TestDiagnostics_ScanBudget` (injected clock) |
| Crash shapes | `panic:`/`fatal error:` + `goroutine` header counted; a timestamped log line containing `panic:` not; time from the preceding timestamped line or `time unknown`; newest by time, then file order | Go `TestDiagnostics_CrashRuntimeHeaders`, `TestDiagnostics_IgnoresLoggedPanicText`, `TestDiagnostics_CrashTimeFromPrecedingLine`, `TestDiagnostics_CrashOrderAcrossFiles` |
| URL too long (incl. Cyrillic, CJK) | steps 2–3 + too-long notice | `ReportProblemLinkTests` (above) |
| Browser does not open | notice + Copy Link; sheet stays | `testBrowserFailureOffersCopyLink` |
| GitHub errors after the browser opened | sheet still open with the text; Open again | `testSheetStaysOpenAfterOpen` |
| No main window / Settings in front | main window fronted, then the sheet | `testMenuFrontsMainWindow` (no window), `testSettingsEntryFrontsVisibleMainWindow` (visible main window behind Settings: `activate` and `makeKeyAndOrderFront` called before presenting; injected windows/activate) |
| User closes mid-way | task cancelled, child terminated, nothing written | `testCancelWhileCollectingTerminates` |
| Save fails | inline notice with the reason, atomic write leaves nothing partial | `testSaveFailureShowsReason` |
| Corp build | no GitHub, no Discussions; Save only | `testCorpBuildOffersSaveOnly` |

**Writers.** None of this data has a writer: the command and the sheet only read. The only writes are the user-chosen file and the pasteboard, each once per user press.

## Paths that change together

- `bug_report.yml` field ids and dropdown option labels ↔ `ReportProblemLink` keys ↔ the Go `chip`/`provider`/`sources` mappings. Go `TestDiagnostics_FormOptions` parses `.github/ISSUE_TEMPLATE/bug_report.yml` and checks every value the mapping can emit is an option; Swift `testLinkKeysMatchForm` checks the keys against the same file's ids.
- CLI start-up: `diagnostics` joins the no-op `PersistentPreRunE` commands and the `sweepStaleTemp` skip in `Execute()`; a change to `ensureSchemaFormat`, `Execute()` or `OpenExisting`'s lock-metrics wiring must keep `TestDiagnostics_WritesNothing` green.
- Corp rule: Go's `flavor` output (`""`/`dev` → `default`, else `corp`) ↔ Swift `HubIdentity.flavor(buildFlavor:)`, which the sheet uses directly (it must decide even when the CLI failed). Pinned on both sides by a shared case table `report_problem_flavor_cases.json`.
- Crash scan ↔ `cmd/logfile.go` (where the daemon's stderr lands, rotation name `.1`, the log timestamp layout) and the Go runtime's crash header.
- `ErrorClass` markers ↔ provider error wording.

## Privacy

- What leaves the Mac: only what the user sees in the sheet and submits on GitHub in their browser, or a file they saved and send themselves. No network call by the app.
- The diagnostics carry kinds, counts, states, error classes, sizes, versions, dates and `default`/`corp`; never anything on the never-printed list.
- **Guard DIAG-01:** `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText` seeds a database, a config and log files with `logcanary.Marker` canaries in every name and text field the command reads around (workspace name, account names, team domains, emails, channel/space/project names, Quick Connection and automation names, `pipeline_runs.error_msg`, account status text, `last_sync.json` error, a panic message in `watchtower.log`, `BuildFlavor`) and asserts neither the text nor the JSON contains the marker, a `/Users/` path or an `<acct>:<id>` shape. Swift `testReportCarriesOnlyCLITextAndUserText`.
- The user's own text is theirs: the sheet says the issue is public; the app does not scan it.

## Decisions

| # | Decision | Source |
|---|---|---|
| 1 | No telemetry, no crash service; the report is user-initiated and the app sends nothing | ask #996 |
| 2 | Build Report a Problem now | ask #1023 |
| 3 | Go `watchtower diagnostics` is the one source; the Desktop shows its text verbatim | ask #1026 |
| 4 | Errors are reported as the last 20 failures, class + phase + time, no text and no log lines | ask #1026 |
| 5 | GitHub only in v1: no email or other channel for people without GitHub | ask #1026 |
| 6 | Corporate builds: Save Diagnostics only, no GitHub, no Discussions | ask #1026 |
| 7 | New inventory entry DIAG-01 with its guard | ask #1026 |
| 8 | Discussions link in the sheet for questions | decided by agent (target #1527 names Discussions) |
| 9 | One user field. The form's Steps and Expected stay on GitHub: the form requires and shows them anyway, so more fields in the sheet would duplicate it; the placeholder asks for all three; the GitHub link carries the text whole unless the budget's step 3 cuts it (then Copy Report has it whole), and Save always writes it whole | decided by agent |
| 10 | On CLI failure the Desktop adds macOS from `ProcessInfo` (a one-line read, no mapping); the chip is left for the user (one click on the form) because mapping it in Swift would duplicate Go's table | decided by agent |
| 11 | Crash: runtime headers only, time from the preceding log line, whole-file streaming scan under a 2 s budget, newest by time then file order | decided by agent |
| 12 | Budget on the encoded URL (6 000), three-step shortening, 2 000-character field cap | decided by agent |
| 13 | Clipboard written only by explicit Copy buttons | decided by agent |
| 14 | The sheet stays open after Open and keeps the text until Done; nothing kept after it closes | decided by agent |
| 15 | The command writes nothing of Watchtower's: no pre-run, no temp sweep, `OpenExisting` + lock-metrics sink off; SQLite's own `-wal`/`-shm` sidecars are the stated exception | decided by agent |
| 16 | Entry points: Help menu, and Settings → System → Logs because that is where someone looking at logs after a failure already is; both always front the main window; no About link, no toolbar button | decided by agent |
| 17 | Only `default`/`corp` is printed, never the raw flavor (it can name the company) | decided by agent |
| 18 | Screenshots and videos are not part of the report (the form's own hint covers them) | decided by agent |
| 19 | Rename the Settings → Logs "Crash Log" tab to **Startup Log**, caption `What the daemon wrote before the Sync Log opened. Crashes are in the Sync Log.` — panics have gone to `watchtower.log` since the stderr redirect, so the old label sends people to the wrong file while they are reporting a problem | decided by agent |
| 20 | Error classifier: fixed order, HTTP codes only in a status form, unknown wordings → `other` | decided by agent |

**Contracts touched:** DIAG-01 (new) and the `watchtower diagnostics` `--json` keys (`text`, `version`, `macos`, `chip`, `provider`, `sources`, `flavor`) — approved in ask #1026. FILES-01 is not changed; decision 4 relies on its limits (logs still carry `<acct>:<id>`). No other inventory contract is touched.

## Mockups

Real SwiftUI shots from `DesignShotCatalog` (`ReportProblemShotFixtures` in `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+ReportProblem.swift`, design-only, sample data only). The PNGs are committed on branch `feat/1527-report-problem` under `docs/design/mockups/report-a-problem/`, each in `-light.png` and `-dark.png`:

| Shot | Shows |
|---|---|
| `report-problem-collecting` | loading/busy: empty field, spinner + "Collecting diagnostics…", Save and Open disabled |
| `report-problem-empty` | ready, nothing typed: full diagnostics, "Describe the problem to continue.", Open disabled |
| `report-problem-filled` | ready, typed: full diagnostics, Discussions link, Cancel · Save Diagnostics… · Open GitHub Issue |
| `report-problem-failed` | error: warning with the 10-second reason, partial lines (app and macOS versions), Retry; Open enabled because text is typed |
| `report-problem-opened` | after Open: green "Opened in your browser…" notice, Cancel became Done |
| `report-problem-tooLong` | after Open over budget: warning "did not fit in the link" + Copy Report, Done |
| `report-problem-browserFailed` | browser did not open: warning + Copy Link, Done |
| `report-problem-saveFailed` | save failed: warning with the reason, buttons unchanged |
| `report-problem-corp` | corporate build: corp intro, `flavor: corp`, no public note, no Discussions, Cancel · Save Diagnostics… (prominent) |
| `report-problem-filled-narrow` | 360 pt: text wraps, buttons stacked, nothing clipped |
| `report-problem-settings-entry` | Settings → System → Logs: Open Logs and Report a Problem… side by side |

Re-render: `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=<dir> swift test --filter DesignShotsTests/testReportProblemShotsRender`. The implementation replaces the fixture's local copy with `ReportProblemCopy`.

## Out of scope / v1 limits

- No email or other channel for people without a GitHub account (ask #1026).
- No upload of logs, screenshots or files by the app; the user attaches a saved `.txt` by hand.
- No in-app issue search, duplicate detection or GitHub sign-in.
- The iPhone app has no Report a Problem in v1.
- Dropdown prefill (`chip`, `provider`) relies on GitHub accepting the exact option label; if it does not, the user picks them (they are in the text anyway).
- Recent errors cover `pipeline_runs` and the last sync result only; account auth problems show as states in `Sources:`, not as timed errors.
- A crash scan cut by its 2 s budget says so instead of guessing.

## Docs

- Guide: `docs/guide/troubleshooting/README.md` gains "Report a problem" (Help → Report a Problem…, what is included, Discussions for questions, `watchtower diagnostics` from the terminal, the corp variant); `.github/ISSUE_TEMPLATE/bug_report.yml`'s `version`/`logs` descriptions mention `watchtower diagnostics`.
- Settings → Logs: the Startup Log rename (decision 19) and the guide page that names the tab.
- Feature note `docs/features/report-a-problem.md` + CLAUDE.md index line; inventory file entry for DIAG-01.
