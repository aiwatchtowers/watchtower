# Report a Problem — design (target #1527)

**Status:** spec, not implemented. **Board:** #1527. **Mockups:** [`docs/design/mockups/report-a-problem/`](../../design/mockups/report-a-problem/README.md) (committed on this branch, `feat/1527-report-problem`).

## Goal

Watchtower has no telemetry and no crash reporting service (ask #996). The only way to hear about a problem on a stranger's Mac is a report the user files. Help → **Report a Problem…** lets them describe it in their own words and opens the GitHub bug form (or an email) already filled with everything the app can work out itself. The app sends nothing: the user sees every character before it leaves and sends it themselves. Questions go to GitHub Discussions.

## Context (recon, 2026-11-04)

- **Help menu.** `HelpCommands` in `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`CommandGroup(after: .help)`: Ask Watchtower… ⌘/, Watchtower User Guide, Keyboard Shortcuts). About is `AboutPanel.show()`. Settings → System is `Views/Settings/SystemSettings.swift` (sections Workspace, AI, Workbench, Sync, Logs (**Open Logs**), Update, Usage). A menu action with no main window open fronts it through `AppState.bringMainWindowForward()` (`askWatchtower` in `App/AppState+HelpChat.swift`).
- **Links.** `ReleaseLinks.repository` (`https://github.com/aiwatchtowers/watchtower`) and `GuideLinks` in WatchtowerCore; external URLs open with `NSWorkspace.shared.open` (returns `false` when nothing opened). No support email address exists anywhere in the repo yet.
- **Version and flavor.** Go `cmd.Version`/`Commit`/`BuildDate`/`BuildFlavor` (ldflags, `scripts/build-app.sh`; `BUILD_FLAVOR` is a free string), printed raw by `watchtower version`. The app has `CFBundleShortVersionString` and `WTBuildFlavor`; `HubIdentity.flavor(buildFlavor:)` treats empty or `dev` as the default build and anything else as a corporate build. The raw flavor string can name the company, so it is never printed — only `default`/`corp`.
- **State the Desktop can read today, scattered:** provider (`ConfigService().aiProvider`), per-service accounts (`ConnectionSummary` over six view models), features (`watchtower features list --json`), daemon (`DaemonManager`, `last_sync.json`), readiness (`ReadinessCenter`), pipeline runs (`PipelineRunQueries`). Quick Connections, policy, schema version and the crash trace are Go-only or file-only.
- **Existing summaries are not safe to share.** `watchtower status` prints the workspace name, team domains and the database path. `pipeline_runs.error_msg`, account status text and backfill `last_error` hold the full provider error text (FILES-01 allows it: only the owner reads them).
- **No class classifier for stored errors.** `ai`/`codex` `classifyError(err, stderr)` work on a live process error, `chat.ClassifyClaudeError(msg)` maps Claude chat errors to chat codes; none maps a stored `error_msg` of any pipeline to a closed class list. A new one is needed.
- **Logs.** `watchtower.log` (sync log, rotates to `watchtower.log.1`), `daemon.log`, `sessions.log` (20 MiB), `dblock.jsonl`. The detached daemon redirects its stderr into `watchtower.log` and follows it across rotations (`cmd/logfile.go` `newSyncLogWriter`/`followStderr`), so **Go panics land in `watchtower.log`/`watchtower.log.1`**; `daemon.log` keeps only what was written before the logger started, or everything if the redirect failed. The Settings → Logs "Crash Log" tab (`LogsSettings.LogFile.daemon`) and its caption ("Go runtime panics, …") are therefore stale — noted for the implementation, see Docs. FILES-01 keeps synced names and text out of the logs, but they still carry account short names and ids (`channel=<acct>:<id>`), and rotated copies from before 2026-10-25 can still hold text.
- **CLI pre-run.** `rootCmd.PersistentPreRunE = ensureSchemaFormat` (`cmd/root.go`): loads the config (fails the command on a broken one), may run `db.RunSchemaUpgrade` and rewrites the config's `db.schema_format`. Commands that must not do this set a no-op `PersistentPreRunE` (`ai`, `code`, `db compact`, `extract-pdf`, `ai routing-status`). `db.Open` migrates; `db.OpenExisting(path, busy)` opens `mode=rw` + `query_only`, no migration, no file creation.
- **CLI calls.** `CLIRunnerProtocol.run(args:timeout:)` (WatchtowerCore) runs the bundled CLI and terminates the child on timeout.
- **No diagnostics feature exists.**
- **GitHub prefill.** `issues/new?template=bug_report.yml&<id>=<value>`; the field `id` is the prefill key (GitHub form-schema doc). Documented for text fields (`input`, `textarea`); dropdowns are known to take an exact option label; checkboxes cannot be prefilled. Past the server limit GitHub answers `414 URI Too Long` (no number documented; ~8 KB in practice). `bug_report.yml` ids: `version`, `macos` (input), `chip`, `provider` (dropdown), `sources` (checkboxes), `steps`, `expected`, `actual`, `logs` (textarea).

## Design

### One source: `watchtower diagnostics` (pending ask #1026)

A new read-only command `watchtower diagnostics [--json] [--app-version <v>]` composes the summary; the Desktop shows its `text` verbatim and builds no line of its own. Go owns every input (config, provider resolution, features registry, every account table, Quick Connections, policy, daemon pid, `pipeline_runs`, goose version, log files) and the new error classifier; a Swift composer would be a Go↔Swift dual path over a dozen readers. A user without the app window gets the same text from the terminal.

**It never writes.** The command sets its own no-op `PersistentPreRunE` (no `ensureSchemaFormat`: no schema upgrade, no config rewrite), loads the config itself and tolerates its absence or a parse error, and opens the database with `db.OpenExisting(path, 2 s)` (no migration, `query_only`). Test `TestDiagnostics_WritesNothing`: a config with `db.schema_format` below current and a database with a pending migration; after the run the config bytes, the database file's hash and the goose version are unchanged.

`--json` pinned keys: `text`, `version`, `macos` (`macOS 15.5`, `sysctl kern.osproductversion`), `chip` (the form's option: `Apple M1`…`Apple M5` from `machdep.cpu.brand_string` with Pro/Max/Ultra dropped, else `Other`), `provider` (the form's option: `Claude Code`/`Codex`/`Ollama (or another local server)`/`Not set up yet`), `sources` (form labels of connected kinds), `flavor` (`default`|`corp`). Plain output prints `text`.

The text, one fact per line:

```
Watchtower <version> (commit <sha>, flavor: default|corp) · app <--app-version>
macOS <x.y> · <chip>
Config: ok | none (not set up) | unreadable (<parse|permission|other>)
AI: <provider> · reserve <provider>, automatic|off
Features on: <feature ids>
Sources: <Kind> <n> ok|<k> needs sign-in|<k> error|purged … ; Quick Connections <n>; iPhone companion on|off
Daemon: running|stopped · last cycle <age> ago, done|error|running
Recent errors (last 20):
  <yyyy-MM-dd HH:mmZ>  <phase>  <class>
Crash: last panic <yyyy-MM-dd HH:mmZ> in <pkg.Func> | no panic in the logs
Logs: watchtower.log <size> · daemon.log <size> (not attached)
Database: schema <goose version> · <size> · managed by organization: yes|no
```

- **Recent errors (pending ask #1026).** The last 20 `pipeline_runs` rows with `status = 'error'` (time = `finished_at` in UTC, phase = `pipeline`, class), plus the last sync result in `last_sync.json` when it failed (phase `sync`). Never the text.
- **Error classes (new).** `diagnostics.ErrorClass(msg string) string` in a new `internal/diagnostics` package maps a stored message to the closed list `auth`, `rate_limit`, `quota`, `timeout`, `network`, `not_found`, `cancelled`, `parse`, `other` by case-insensitive markers (e.g. `401`/`403`/`invalid_auth`/`token revoked` → `auth`; `429`/`rate limit` → `rate_limit`; `usage limit`/`quota`/`credit` → `quota`; `deadline exceeded`/`timed out` → `timeout`; `connection refused`/`no such host`/`network is unreachable` → `network`; `404`/`not found` → `not_found`; `context canceled` → `cancelled`; `unmarshal`/`invalid character`/`parse` → `parse`). Table test `TestErrorClass` covers every class and an unknown message (`other`).
- **Crash.** Reads the last 256 KB of `watchtower.log`, `watchtower.log.1` and `daemon.log` (each), finds the newest `panic: ` line and reports its log timestamp (or the file's mtime when the line has none) and the first following frame starting with `watchtower/` — code, not data. The panic message is never printed.
- **Never printed:** workspace name, account/team/site names and domains, emails, ids, channel/project/space names, Quick Connection and automation names, paths, raw flavor, model output, error text, log lines.
- **Partial output.** Every line is computed independently; a failing reader prints `unknown (<reason>)` on its own line and the command still exits 0. No config: Config, AI, Features, Sources, Recent errors and Database print `unknown (no config)`; Logs prints `unknown`. No or locked database: Sources, Recent errors and Database print `unknown (no database|database busy)`; Config, AI, Features, Daemon, Crash and Logs still print.

### The sheet

Help → **Report a Problem…** (after Watchtower User Guide) and **Report a Problem…** in Settings → System → Logs open one sheet on the main window, fronted first with `bringMainWindowForward()` when it is closed or hidden (the menu works with no window open). The style guide allows a sheet for a short one-field form.

Layout (see mockups): title, intro, **What happened?** field (≤ 2 000 characters), the diagnostics block exactly as it will be sent (monospaced, selectable, in a card), the public-issue note, a quiet **A question, not a problem? Ask in Discussions** link (`ReleaseLinks.repository/discussions`), and Cancel · **Save Diagnostics…** · **Email** · **Open GitHub Issue** (the one prominent action). The buttons stack vertically when the sheet is narrow.

**Corporate build (pending ask #1026).** When `HubIdentity.bundleFlavor()` is `.corp`, the sheet shows the corp intro, no public note, no Discussions link and only Cancel · **Save Diagnostics…** (prominent). Nothing points at the public tracker.

**Email (pending ask #1026).** Opens `mailto:<ReleaseLinks.supportEmail>?subject=<title>&body=<report>`. The address is the owner's to give; while `supportEmail` is unset the button is not shown.

States (`ReportProblemModel` in WatchtowerCore, `@Observable`, the view owns no logic):

| State | Diagnostics block | Buttons |
|---|---|---|
| collecting | progress + "Collecting diagnostics…" | Save, Email, Open disabled |
| ready | the text | Email/Open need text (below) |
| failed | warning + reason, partial lines `Watchtower app <bundle version>` and `macOS <x.y>` (from `ProcessInfo`), **Retry** | Save enabled; Email/Open need text |
| opened | unchanged; "Opened in your browser…" notice | Cancel becomes **Done** |
| too long | unchanged; notice + **Copy Report** | **Done** |
| browser / mail app failed | unchanged; notice + **Copy Link** | **Done** |
| save failed | unchanged; inline notice | unchanged |

**Rule:** Email and Open GitHub Issue are disabled while "What happened?" is empty (trimmed) in every state, failed included; Save Diagnostics… is enabled in every state but collecting. Test `testSendNeedsTextInEveryState`.

**The sheet stays open after Open GitHub Issue / Email** and keeps the text until **Done** or Cancel, so a GitHub error (sign-in, 414, network) loses nothing; pressing Open again rebuilds the link. Nothing is kept after the sheet closes.

### The link

`ReportProblemLink.make(report:channel:)` (pure, WatchtowerCore) builds the GitHub link — `template=bug_report.yml`, `title=<first line of the user text, ≤ 80 characters>`, `version`, `macos`, `chip`, `provider`, `actual=<user text>`, `logs=<diagnostics text>` — or the mailto link (`subject`, `body` = user text + diagnostics). Steps and expected are not separate fields (see Decisions); `sources` is not a URL field (checkboxes), the kinds are in the `Sources:` line. On a failed collection the link carries `version` (bundle) and `macos` (`ProcessInfo`) only; chip and provider are left for the user.

**Budget, by encoded length.** The limit applies to the final percent-encoded URL: 6 000 characters for GitHub, 1 800 for mailto (mail clients cut long `mailto:` links). One Cyrillic character costs 6 encoded characters, a CJK one 9, so a character cap alone does not fit. Steps, in order, stopping at the first that fits:
1. Full link.
2. `logs` (or the mail body's diagnostics) replaced by `Paste the report from Watchtower here.`
3. `actual` also cut at a character boundary to what still fits, ending with `… (full text in the pasted report)`.

From step 2 on, the sheet shows the "too long" notice with **Copy Report** (user text + diagnostics). Tests `ReportProblemLinkTests`: ASCII, Cyrillic and CJK texts at the 2 000 cap each produce a link within budget; step 3 never splits a character or a percent escape; a short text yields the full link.

**Clipboard rule.** The app writes the clipboard only when the user presses a Copy button — never on its own. **Copy Report** writes the report, **Copy Link** writes the link; each press replaces the previous item and the notice says what was copied ("Report copied." / "Link copied."). Test `testClipboardWrittenOnlyByCopyButtons` (injected pasteboard: opening, failing to open and saving write nothing).

**Save Diagnostics…** — `NSSavePanel`, default `watchtower-diagnostics-<yyyy-MM-dd>.txt`, writes the report (user text, if any, + diagnostics), atomically.

## UI strings (in `ReportProblemCopy`, pinned by `ReportProblemCopyTests`)

| Key | Text |
|---|---|
| menu, title | `Report a Problem…`, `Report a Problem` |
| intro | `Tell us what went wrong. Watchtower sends nothing itself: you review everything below and send it yourself.` |
| corp intro | `This is your organization's build. Save the diagnostics and send the file to your IT team.` |
| field | `What happened?` / placeholder `What you did, what you expected, what you saw instead.` / `Describe the problem to continue.` |
| block | `Diagnostics that will be included` / `Kinds, counts, states and error classes only — no names, ids, message text or log lines.` |
| loading | `Collecting diagnostics…` |
| failed | `Could not collect diagnostics: <reason>. The report will carry the app and macOS versions only.`; reasons `the watchtower command did not answer in 10 seconds`, `the watchtower command is missing`, `the watchtower command failed (exit <n>)`, `its answer could not be read`; `Retry` |
| notes | `GitHub issues are public. Check the text before you submit.` / `A question, not a problem? Ask in Discussions` |
| buttons | `Cancel`, `Done`, `Save Diagnostics…`, `Email`, `Open GitHub Issue`, `Copy Report`, `Copy Link` |
| results | `Opened in your browser. Finish the issue there; this window keeps your text until you press Done.` / `Opened in your mail app. This window keeps your text until you press Done.` / `The report did not fit in the link. Copy it and paste it into Logs on GitHub.` (mail: `… paste it into the message.`) / `Report copied.` / `Link copied.` |
| errors | `Could not open your browser. Copy the link and paste it into a browser.` / `No mail app opened. Copy the report and send it to <address>.` / `Could not save the file: <localized reason>` |
| link placeholders | `Paste the report from Watchtower here.` / `… (full text in the pasted report)` |

Colors only through `Tone` (`Tone.warning` for failures and the too-long notice, `Tone.success` for opened); kit buttons, `.card()` groups, no row separators, no stock form chrome.

## Failure modes

| Path | Behaviour | Test |
|---|---|---|
| CLI missing | failed, reason "missing"; link carries app + macOS versions | `ReportProblemModelTests.testMissingCLI` |
| CLI times out (10 s) | runner terminates the child; failed + Retry | `testTimeoutShowsRetry` |
| CLI exits non-zero / bad JSON | failed with the exit code / "could not be read" | `testNonZeroExit`, `testUndecodableJSON` |
| Link in failed state | `version` + `macos` only, no `chip`/`provider`/`logs` diagnostics | `ReportProblemLinkTests.testFailedStateLink` |
| Config missing / broken | command exits 0; `Config:` line says why; config-dependent lines `unknown (no config)` | Go `TestDiagnostics_NoConfig`, `TestDiagnostics_BrokenConfig` |
| Database missing or locked | Sources, Recent errors, Database `unknown (…)`; the rest prints | Go `TestDiagnostics_NoDatabase`, `TestDiagnostics_LockedDatabase` |
| Log file missing / unreadable | `watchtower.log missing` / `unreadable`; Crash `unknown` for that file | Go `TestDiagnostics_LogMissing`, `TestDiagnostics_LogUnreadable` |
| Huge log | only the last 256 KB of each scanned file is read | Go `TestDiagnostics_HugeLogReadsTail` |
| Panic in `watchtower.log.1` / `daemon.log` | found in either; newest wins | Go `TestDiagnostics_PanicInRotatedLog`, `TestDiagnostics_PanicInDaemonLog` |
| URL too long (incl. Cyrillic, CJK) | steps 2–3 + too-long notice | `ReportProblemLinkTests` (above) |
| Browser / mail app does not open | notice + Copy Link (mail: Copy Report + address); sheet stays | `testBrowserFailureOffersCopyLink`, `testMailFailureOffersCopyReport` |
| GitHub errors after the browser opened | sheet still open with the text; Open again | `testSheetStaysOpenAfterOpen` |
| No main window | window fronted, then the sheet | `testMenuFrontsMainWindow` (injected window opener) |
| User closes mid-way | task cancelled, child terminated, nothing written | `testCancelWhileCollectingTerminates` |
| Save fails | inline notice with the reason, atomic write leaves nothing partial | `testSaveFailureShowsReason` |
| Corp build | no GitHub, Email, Discussions; Save only | `testCorpBuildOffersSaveOnly` |

**Writers.** None of this data has a writer: the command and the sheet only read. The only writes are the user-chosen file and the pasteboard, each once per user press.

## Paths that change together

- `bug_report.yml` field ids and dropdown option labels ↔ `ReportProblemLink` keys ↔ the Go `chip`/`provider`/`sources` mappings. Go test `TestDiagnostics_FormOptions` parses `.github/ISSUE_TEMPLATE/bug_report.yml` and checks every value the mapping can emit is an option; Swift `testLinkKeysMatchForm` checks the keys against the same file's ids.
- The root pre-run bypass: `diagnostics` joins the no-op `PersistentPreRunE` commands; a change to `ensureSchemaFormat` or to how commands opt out must keep `TestDiagnostics_WritesNothing` green.
- Corp rule: Go's `flavor` output (`""`/`dev` → `default`, else `corp`) ↔ Swift `HubIdentity.flavor(buildFlavor:)`, which the sheet uses directly (it must decide even when the CLI failed). Pinned on both sides by a shared case table `report_problem_flavor_cases.json`.
- Panic scan ↔ `cmd/logfile.go` (which file the daemon's stderr lands in, rotation name `.1`).
- `ErrorClass` markers ↔ provider error wording; an unknown wording falls to `other`, never to a wrong class.

## Privacy

- What leaves the Mac: only what the user sees in the sheet and sends themselves — the GitHub form in their browser, an email from their mail app, or a file they saved. No network call by the app.
- The diagnostics carry kinds, counts, states, error classes, sizes, versions, dates and `default`/`corp`; never anything on the never-printed list.
- **Guard DIAG-01 (pending ask #1026):** `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText` seeds a database, a config and log files with `logcanary.Marker` canaries in every name and text field the command reads around (workspace name, account names, team domains, emails, channel/space/project names, Quick Connection and automation names, `pipeline_runs.error_msg`, account status text, `last_sync.json` error, a panic message in `watchtower.log`, `BuildFlavor`) and asserts neither the text nor the JSON contains the marker, a `/Users/` path or an `<acct>:<id>` shape. Swift `testReportCarriesOnlyCLITextAndUserText`.
- The user's own text is theirs: the sheet says the issue is public; the app does not scan it.

## Decisions

| # | Decision | Source |
|---|---|---|
| 1 | No telemetry, no crash service; the report is user-initiated and the app sends nothing | ask #996 |
| 2 | Build Report a Problem now | ask #1023 |
| 3 | Go `watchtower diagnostics` is the one source; the Desktop shows its text verbatim | pending ask #1026 |
| 4 | Errors are reported as the last 20 failures, class + phase + time, no text and no log lines | pending ask #1026 |
| 5 | People without GitHub: an **Email** button (mailto to the owner's support address; hidden until one is set) | pending ask #1026 |
| 6 | Corporate builds: Save Diagnostics only, no GitHub, Email or Discussions | pending ask #1026 |
| 7 | New inventory entry DIAG-01 with its guard | pending ask #1026 |
| 8 | Discussions link in the sheet for questions | decided by agent (target #1527 names Discussions) |
| 9 | One user field. The form's Steps and Expected stay on GitHub: the form requires them and shows them anyway, a second and third field in the sheet would duplicate it; the placeholder asks for all three, and email/save carry the text whole | decided by agent |
| 10 | On CLI failure the Desktop adds macOS from `ProcessInfo` (a one-line read, no mapping); the chip is left for the user (one click on the form) because mapping it in Swift would duplicate Go's table | decided by agent |
| 11 | Crash line: panic time + first `watchtower/…` frame, from `watchtower.log`, `.1` and `daemon.log` | decided by agent |
| 12 | Budget on the encoded URL (6 000 GitHub, 1 800 mailto), three-step shortening, 2 000-character field cap | decided by agent |
| 13 | Clipboard written only by explicit Copy buttons | decided by agent |
| 14 | The sheet stays open after Open/Email and keeps the text until Done; nothing kept after it closes | decided by agent |
| 15 | The command bypasses the root pre-run and opens the database with `OpenExisting` (no writes, no migration) | decided by agent |
| 16 | Entry points: Help menu, and Settings → System → Logs because that is where someone looking at logs after a failure already is; no About link, no toolbar button | decided by agent |
| 17 | Only `default`/`corp` is printed, never the raw flavor (it can name the company) | decided by agent |
| 18 | Screenshots and videos are not part of the report (the form's own hint covers them) | decided by agent |

**Contracts touched that the owner has not approved:**
- **DIAG-01** (new inventory entry) and the `watchtower diagnostics` command with pinned `--json` keys (`text`, `version`, `macos`, `chip`, `provider`, `sources`, `flavor`) — pending ask #1026.
- **FILES-01** is not changed, but decision 4 relies on its limits (logs still carry `<acct>:<id>`).

## Mockups

Real SwiftUI shots from `DesignShotCatalog` (`ReportProblemShotFixtures` in `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+ReportProblem.swift`, design-only, sample data only), light and dark, in [`docs/design/mockups/report-a-problem/`](../../design/mockups/report-a-problem/README.md): `report-problem-collecting` (loading/busy), `-empty`, `-filled`, `-failed` (error with Retry), `-opened`, `-tooLong`, `-browserFailed`, `-saveFailed`, `-corp`, `-filled-narrow` (360 pt). Re-render: `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=<dir> swift test --filter DesignShotsTests/testReportProblemShotsRender`. The implementation replaces the fixture's local copy with `ReportProblemCopy`.

## Out of scope / v1 limits

- No upload of logs, screenshots or files by the app; the user attaches a saved `.txt` by hand.
- No in-app issue search, duplicate detection or GitHub sign-in.
- The iPhone app has no Report a Problem in v1.
- Dropdown prefill (`chip`, `provider`) relies on GitHub accepting the exact option label; if it does not, the user picks them (they are in the text anyway).
- Recent errors cover `pipeline_runs` and the last sync result only; account auth problems show as states in `Sources:`, not as timed errors.

## Docs

- Guide: `docs/guide/troubleshooting/README.md` gains "Report a problem" (Help → Report a Problem…, what is included, Discussions for questions, `watchtower diagnostics` from the terminal, the corp variant); `.github/ISSUE_TEMPLATE/bug_report.yml`'s `version`/`logs` descriptions mention `watchtower diagnostics`.
- Settings → Logs: rename the stale "Crash Log" tab/caption (panics are in the Sync Log since the stderr redirect); a one-line fix in the same PR.
- Feature note `docs/features/report-a-problem.md` + CLAUDE.md index line; inventory file for DIAG-01 after ask #1026.
