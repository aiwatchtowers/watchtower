# Report a Problem — design (target #1527)

**Status:** spec, not implemented. **Board:** #1527. **Mockups:** [`docs/design/mockups/report-a-problem/`](../../design/mockups/report-a-problem/README.md) on branch `feat/1527-report-problem` (listed with descriptions under Mockups below).

## Goal

Watchtower has no telemetry and no crash reporting service (ask #996). The only way to hear about a problem on a stranger's Mac is a report the user files. Help → **Report a Problem…** lets them describe it in their own words and opens the GitHub bug form already filled with everything the app can work out itself. The app sends nothing: the user sees every character before it leaves and submits it on GitHub themselves. Questions go to GitHub Discussions.

## Context (recon, 2026-11-04)

**Code references are as of main `feb9c2054` (2026-11-08, after PR #686 "Codex parity and LLM transport independence"), merged into this branch at `3743951a3`;** every file, function and line named in this spec was re-checked there on 2026-11-10.

- **Help menu.** `HelpCommands` in `WatchtowerDesktop/Sources/App/WorkbenchCommands.swift` (`CommandGroup(after: .help)`: Ask Watchtower… ⌘/, Watchtower User Guide, Keyboard Shortcuts). About is `AboutPanel.show()`. Settings → System is `Views/Settings/SystemSettings.swift`; its Logs section has one button, **Open Logs**. `AppState.bringMainWindowForward(windows:activate:)` (`App/AppState+Automations.swift`) activates the app and calls `makeKeyAndOrderFront` on a visible or miniaturised main window, or opens one; both seams are injectable.
- **Links.** `ReleaseLinks.repository` (`https://github.com/aiwatchtowers/watchtower`) and `GuideLinks` in WatchtowerCore; external URLs open with `NSWorkspace.shared.open` (returns `false` when nothing opened).
- **Version and flavor.** Go `cmd.Version`/`Commit`/`BuildDate`/`BuildFlavor` (ldflags, `scripts/build-app.sh`; `BUILD_FLAVOR` is a free string), printed raw by `watchtower version`. The app has `CFBundleShortVersionString` and `WTBuildFlavor`; `HubIdentity.flavor(buildFlavor:)` treats empty or `dev` as the default build and anything else as a corporate build. The raw flavor string can name the company, so it is never printed — only `default`/`corp`.
- **State the Desktop can read today, scattered:** provider (`ConfigService().aiProvider`), per-service accounts (`ConnectionSummary` over six view models), features (`watchtower features list --json`), daemon (`DaemonManager`, `last_sync.json`), readiness (`ReadinessCenter`), pipeline runs (`PipelineRunQueries`). Quick Connections, policy, schema version and crash traces are Go-only or file-only.
- **Existing summaries are not safe to share.** `watchtower status` prints the workspace name, team domains and the database path. `pipeline_runs.error_msg`, account status text and backfill `last_error` hold the full provider error text (FILES-01 allows it: only the owner reads them).
- **No class classifier for stored errors.** `ai`/`codex` `classifyError(err, stderr)` (`internal/ai/client.go:1260`, `internal/codex/generator.go:441`) work on a live process error; `chat.ClassifyClaudeError(msg)` (`internal/chat/claude_translate.go:692`) maps Claude chat errors to chat codes; PR #686's `providers.Failure` carries an `ErrorCategory` on the live error, but its `Error()` is the cause's text (`internal/providers/failure.go:48`), so a stored `pipeline_runs.error_msg` keeps no category. Nothing maps a stored message to a closed class list.
- **Provider validation (main `feb9c2054`).** `config.Load` calls `cfg.AI.Validate()` right after the unmarshal and returns its error (`internal/config/config.go:619`: `if err := cfg.AI.Validate(); err != nil { return nil, err }`). `AIConfig.Validate` (`internal/config/ai_routing.go:11`) treats an empty preferred provider as `DefaultAIProvider` (`claude`) and rejects: an unknown preferred provider (`KnownAIProvider`, `ai_routing.go:50`: `claude`/`codex`/`ollama`), an unknown `ai.providers.<id>` bucket, an unknown fallback provider, a fallback equal to the preferred one, a fallback outside a Claude/Codex pair, and `fallback.enabled` without such a pair. `providers.ByID` (`internal/providers/registry.go:128`) resolves an unknown or empty id to `registry[0]`, Claude. Every `providers.ByID(cfg.AI.Provider)` call site (`cmd/ai_session_gate.go:65`, `cmd/transport_wiring.go:53/67/201/249`, `cmd/ai.go:318/482`, `cmd/generator.go:194`, `cmd/tool_routing.go:48`, `cmd/workbench_spec_review.go:108`) runs after a successful `Load`, so an unknown configured value never reaches `ByID`. The one path that skips `Validate` is the per-command `--provider` flag (`cmd/generator.go:645`: `cfg.AI.Provider = flagProvider`), where an unknown flag value falls to Claude through `ByID`; diagnostics never applies `--provider`, so this fallback does not affect the report.
- **Logs.** `watchtower.log` (sync log, `maxLogSize` 20 MiB, rotates to `watchtower.log.1`), `daemon.log`, `sessions.log` (20 MiB), `dblock.jsonl`. The detached daemon redirects its stderr into `watchtower.log` and follows it across rotations (`cmd/logfile.go` `newSyncLogWriter`/`followStderr`), so **Go panics land in `watchtower.log`/`.1`**; `daemon.log` keeps only what was written before the logger started, or all stderr if the redirect failed (older installs: an unbounded `daemon.log` from before the redirect). Log-package lines start with a `2006/01/02 15:04:05` timestamp; the Go runtime's crash output (`panic: …`, `fatal error: …`, then `goroutine N [running]:`) has none. The Settings → Logs "Crash Log" tab (`LogsSettings.LogFile.daemon`) and its caption ("Go runtime panics, …") are stale. FILES-01 keeps synced names and text out of the logs, but they still carry account short names and ids (`channel=<acct>:<id>`), and rotated copies from before 2026-10-25 can still hold text.
- **CLI start-up side effects.** `Execute()` (`cmd/root.go`) starts `sweepStaleTemp()` (removes Watchtower's expired temp files from the system temp dir) for every command; `rootCmd.PersistentPreRunE = ensureSchemaFormat` loads the config (fails the command on a broken one), may run `db.RunSchemaUpgrade` and rewrites the config's `db.schema_format`. Commands that must not do this set a no-op `PersistentPreRunE` (`ai`, `code`, `db compact`, `extract-pdf`, `ai routing-status`). `db.Open` migrates; `db.OpenExisting(path, busy)` opens `mode=rw` + `query_only`, never creates the file and runs no migration, but SQLite may create the `-wal`/`-shm` sidecars when none exist, and the open points the lock-metrics sink at `dblock.jsonl` (`lockmetrics.Configure`; `Configure("")` turns it off).
- **CLI calls.** `CLIRunnerProtocol.run(args:timeout:)` (WatchtowerCore) runs the bundled CLI and terminates the child on timeout.
- **No diagnostics feature exists.**
- **GitHub prefill.** `issues/new?template=bug_report.yml&<id>=<value>`; the field `id` is the prefill key (GitHub form-schema doc). Documented for text fields (`input`, `textarea`); dropdowns are known to take an exact option label; checkboxes cannot be prefilled. Past the server limit GitHub answers `414 URI Too Long` (no number documented; ~8 KB in practice). `bug_report.yml` ids: `version`, `macos` (input), `chip`, `provider` (dropdown), `sources` (checkboxes), `steps`, `expected`, `actual`, `logs` (textarea).

## Design

### One source: `watchtower diagnostics`

A new read-only command `watchtower diagnostics [--json] [--app-version <v>] [--iphone on|off]` composes the summary; the Desktop shows its `text` verbatim and builds no line of its own. Go owns every input (config, provider resolution, features registry, every account table, Quick Connections, policy, daemon pid, `pipeline_runs`, goose version, log files) and the new error classifier; a Swift composer would be a Go↔Swift dual path over a dozen readers. A user without the app window gets the same text from the terminal.

**Failures, timeouts and missing inputs — where each is defined.** Every input in that list has its own row, with the exact printed text and a test, in "Inputs, and what each does when it fails" below; the anchors are the row names:
- config → row **Config**; workspace → row **Workspace** (and "Paths without a fatal helper");
- provider resolution, preferred → row **AI provider**; provider fallback and buckets → row **AI fallback and buckets**; what the AI line and JSON `provider` print in every config state → table **AI line by config state** (defined once; every other mention points there);
- features registry → row **Features**;
- each account table → row **Accounts** (with the Sources mapping, one table per kind, each failing on its own); Quick Connections → row **Quick Connections**;
- policy → row **Policy**; iPhone → row **iPhone companion**;
- daemon pid and `last_sync.json` → rows **Daemon** and **last_sync.json**;
- `pipeline_runs` → row **Recent errors**; error classes → row **Error class**;
- goose version and file size → row **Schema, size**; opening the database → row **Database open / read**;
- log files → row **Log sizes**; crash scan → row **Crash**; anything else → row **Any input**.

The three budgets have defined outputs in "Budget outputs" under Time budget. All line texts are constants in `internal/diagnostics/text.go` (the model), pinned by `TestDiagnosticsText_Pinned`; the table-driven `TestDiagnostics_InputFailures` has one case per row of the Inputs table and per budget, asserting the exact line.

**What it writes: never the main database file and none of Watchtower's own files; SQLite's `-wal`/`-shm` side files are the one stated exception.** Exactly:
- a no-op `PersistentPreRunE` (no `ensureSchemaFormat`: no schema upgrade, no config rewrite). The command checks the config file's existence with `os.Stat` first, as `ensureSchemaFormat` does (not-exist → `Config: none (not set up)`), then calls `config.Load`; a load error is reported, not fatal;
- no features migration: the command never calls `config.MigrateFeatureGates` (see Features below);
- no pid-file cleanup: `daemon.FindProcess` → `resolveProcess` removes a stale pid file (`removeStalePIDFile`), so the command uses a new `daemon.PeekProcess(path) (pid int, state PeekState, err error)` (the five states in the Daemon row of the Inputs table): `resolveProcess` gains a `removeStale bool` parameter, `FindProcess` (and every other existing caller) passes `true` and behaves as today, `PeekProcess` passes `false`. Test `internal/daemon::TestPeekProcess_LeavesStalePIDFile`;
- `Execute()` starts the stale-temp sweep through `shouldSweepTemp(role)`, which is false for `cli:diagnostics`;
- the database is opened with the new `db.OpenExistingContext(ctx, path, 500 ms)` — `OpenExisting`'s DSN (`mode=rw` + `_query_only=1`), no migration, `PingContext(ctx)` — through a connector that turns off SQLite's checkpoint on close; then `lockmetrics.Configure("")`, so no `dblock.jsonl` line. `query_only` refuses every write statement.
- **No checkpoint, ever (ask #1033).** By default SQLite checkpoints the WAL into the main file when the last connection to a database closes; on a stopped install with a left-over WAL that would write `watchtower.db`. The diagnostics connection prevents it:
  - `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` (SQLite ≥ 3.16; the engine is 3.53.4) set on the connection right after open, so closing never checkpoints and never removes the WAL;
  - `PRAGMA wal_autocheckpoint = 0` for the session (belt and braces: a `query_only` connection never commits, so autocheckpoint has nothing to trigger on).
  - **Seam.** The in-repo driver has no way to reach this today: `sqlcipher.Connector.Connect` opens through a package-level `SQLiteDriver` with no `ConnectHook`, and `sqlite3_db_config` is variadic, so cgo needs a C wrapper. The smallest change: `internal/sqlcipher.Connector` gains one field, `NoCheckpointOnClose bool`; when set, `Connect` calls a C helper `wt_no_ckpt_on_close(db)` (`sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &out)`, failing the connect unless `out == 1`) and runs `PRAGMA wal_autocheckpoint = 0`. In `internal/db`, `OpenExistingContext` builds its pool from `lockmetrics.Wrap(&sqlcipher.Connector{…, NoCheckpointOnClose: true}, dsn)` (a small `openExistingWith(ctx, dbPath, connector)` beside `openExistingDSN`); every other connector leaves the field false and behaves as today. Test `internal/sqlcipher::TestConnector_NoCheckpointOnClose` (the left-over-WAL case below, main file hash unchanged; the same case without the flag checkpoints).
- **The exception — SQLite's side files only, measured.** Two throwaway experiments (2026-11-04, `internal/db`, a WAL database written by a second connection, every file's size and sha256 recorded before and after one `SELECT count(*)` and close; not committed). The first compared open modes; the second ran the chosen opener with `NO_CKPT_ON_CLOSE` + `wal_autocheckpoint = 0` (SQLite reported the setting as `1` and the pragma as `0`; every read returned 3 rows):

  | Situation | **Chosen:** `mode=rw` + `query_only` + no checkpoint on close | `mode=rw` + `query_only` (default close) | `mode=ro` + `query_only` | `mode=ro&immutable=1` |
  |---|---|---|---|---|
  | Writer running, frames in the WAL | main file **identical** (4 096 B, same sha256); `-wal` identical; `-shm` content changes (read mark) | `-shm` changes; nothing else | `-shm` changes; nothing else | no file changes, **but the WAL is ignored: `no such table`** |
  | Writer stopped cleanly (no `-wal`/`-shm`) | main file **identical** (8 192 B, same sha256); a 0-byte `-wal` and a 32 KB `-shm` are created and stay | no change (side files created and removed on close) | creates a 0-byte `-wal` and a `-shm`, leaves them | not run |
  | Writer gone, `-wal`/`-shm` left over | main file **identical** (4 096 B, same sha256); `-wal` identical (12 392 B); `-shm` content changes (wal-index rebuilt / read mark) | **close checkpoints into the main file (4 096 → 8 192 B, new sha256) and removes `-wal`/`-shm`** | `-shm` changes, files stay | no change, **WAL ignored** |

  So the main database file is byte-identical in all three situations, and the only files that change are SQLite's own `-shm` (read marks, wal-index) and, on a cleanly stopped install, a new empty `-wal` + `-shm` pair — which the next normal open (the app or daemon) uses and cleans up as usual. `immutable=1` reads a stale or empty picture whenever the daemon has recent data in the WAL, so it is rejected; `mode=ro` gains nothing over the chosen opener. No Watchtower file (config, pid file, logs, `last_sync.json`, `dblock.jsonl`, temp files, other data files) is created, changed or removed.

Test `TestDiagnostics_WritesNothing` (three database situations from the table, each run):
- seeds a config with `db.schema_format` below current and no `features.migrated` marker, a database with a pending migration and committed frames in its WAL, a **stale pid file** (a pid of a process that has exited), `last_sync.json`, logs and a stale temp file;
- after the run: the config, pid file, `last_sync.json`, logs and temp file are byte-identical with the same mtime, the data directory has no new or missing entries except the database's own `-wal`/`-shm`, the goose version is unchanged, every table's rows (`SELECT * … ORDER BY rowid` hashed per table) are identical, and **the main database file's size and sha256 are unchanged in all three situations, including the left-over-WAL one** (`TestDiagnostics_LeftOverWALMainFileUntouched` is that case on its own, with the `-wal` hash also unchanged);
- the temp sweep is made deterministic through a package seam `startTempSweep` (production: `go sweepStaleTemp()`; the test swaps in a synchronous call): the temp file matching `fsutil.StaleTempPatterns`, mtime set 20 min back (older than `staleTempAge`, 10 min), survives `diagnostics`, and the control case runs `version` through the same seam and sees it removed, so the test fails if the skip is lost.

`--json` pinned keys: `text`, `version`, `macos` (`macOS 15.5`, `sysctl kern.osproductversion`), `chip` (the form's option: `Apple M1`…`Apple M5` from `machdep.cpu.brand_string` with Pro/Max/Ultra dropped, else `Other`), `provider` (the form's option of the effective provider: `Claude Code`/`Codex`/`Ollama (or another local server)`; `Not set up yet` only when there is no config file at all; `""` when the config is invalid — see the AI row), `sources` (form labels of connected kinds), `flavor` (`default`|`corp`), `partial` (`true` when any budget ran out or an input timed out; see Budget outputs). Plain output prints `text`.

The text, one fact per line:

```
Watchtower <version> (commit <sha>, flavor: default|corp) · app <--app-version>
macOS <x.y> · <chip>
Config: ok | none (not set up) | unreadable (parse|permission|other) | unknown (no home directory)
Workspace: not chosen (<n> found) | none yet | unknown (invalid name|not found|lookup failed|no home directory)   ← only when no workspace resolves; it replaces every workspace line
AI: Claude Code|Codex|Ollama[ (default, not chosen)|(from environment)] | unknown (not a known provider) · reserve <provider>, automatic|off
Features on: <feature ids>
Sources: <Kind> <n> [ok|<k> needs sign-in|<k> error|<k> purged|<k> off] · … · Quick Connections <n> · iPhone companion on|off
Daemon: running | stopped | stopped (stale pid file) | unknown (process not confirmed) | unknown (pid file corrupt) | unknown (pid file unreadable: permission|other) · last cycle <age> ago, done|error|running | no cycle yet | last cycle unknown
Recent errors (last 20):
  <yyyy-MM-dd HH:mmZ>  <phase>  <class>
  (or: pipeline runs unknown (<reason>), followed by the sync row)
Crash: none in the logs | <n> in the logs, last after <yyyy-MM-dd HH:mmZ>, in <place> | <n> in the logs, last time unknown, in <place>
Logs: watchtower.log <size> · daemon.log <size> (not attached)
Database: schema <goose version> · <size> · managed by organization: yes|yes (with errors)|no
Partial report: <reasons>   ← only when partial (see Budget outputs)
```

- **Line parts.** A line is made of parts, and each part fails on its own: a database part that is busy or missing prints `unknown (<reason>)` in its place while the file- and flag-based parts of the same line still print — `Sources: unknown (database busy) · iPhone companion on`, `Database: schema unknown (database busy) · 1.2 GB · managed by organization: no`, and in Recent errors the sync row from `last_sync.json` under `pipeline runs unknown (database busy)` (mockup `report-problem-busy`).
- **Sources.** One aggregate read per table, `GROUP BY status` (and `enabled` where the table has it). The tables and the mapping of every status value in `schema.sql`:

  | Kind (form label) | Table, filter | Counted as |
  |---|---|---|
  | Slack | `slack_accounts` | `ok` → ok; `error` → error; `revoked` → needs sign-in; `purged` → purged; `removed` → **not counted**; `enabled = 0` → off |
  | Gmail / Google Calendar | `google_accounts` with `gmail_enabled = 1` / `calendar_enabled = 1` (one account can count for both) | `ok`, `error`, `revoked`, `purged` as above |
  | Jira | `jira_accounts` | as Slack, incl. `removed` → not counted, `enabled = 0` → off |
  | Confluence | `ext_sources` with `provider = 'confluence'` (spaces, shown as `<n> spaces`) | `status` CHECK `ok`/`error`/`needs_consent`/`revoked`: `ok` → ok; `error` → error; `needs_consent` and `revoked` → needs sign-in; `enabled = 0` → off |
  | Linear | `linear_accounts` | as Slack |
  | Email over IMAP | `email_accounts` with `provider = 'imap'` (text: `Email (IMAP) <n>`) | `ok`, `error`, `revoked` |
  | Outlook | `email_accounts` with `provider = 'outlook'` (text: `Outlook <n>`) — Microsoft mail synced over IMAP with OAuth (`internal/imap/outlook_auth.go`); the form has no Outlook checkbox, so JSON `sources` maps it to `Email over IMAP` | `ok`, `error`, `revoked` |
  | Calendar (CalDAV/ICS) — **not a form option** | `calendar_accounts` | `ok`, `error`, `revoked`; shown in the text line, omitted from JSON `sources` |
  | Quick Connections | `external_connections` with `enabled = 1` | count only |

  A status value not in the table prints as `<k> unknown state`. A kind is "connected" for the JSON `sources` list when it has at least one counted account; removed accounts never count. JSON `sources` holds only the form's checkbox labels: Slack, Gmail, Google Calendar, Jira, Confluence, Linear, Email over IMAP, and `iPhone companion` when `--iphone on`; CalDAV/ICS calendars and Quick Connections have no checkbox and appear in the text line only. Guard `TestDiagnostics_AccountTablesMapped`: on a fully migrated test database it lists every table matching `%_accounts` from `sqlite_master` and fails when one has no mapping here, so a new source cannot be silently missing from the report.
- **Features.** The same evaluation as `watchtower features list` (`features.All()` + `Feature.Enabled(cfg)`), on the loaded config, read-only. FEAT-01's one-time migration (`config.MigrateFeatureGates`, docs/inventory/features.md, "One write from a read command") is never run here. On an install without the `features.migrated` marker whose `digest.enabled` is explicitly false — a legacy install the daemon has not started on yet — the command applies the existing legacy mapping in memory. The loaded `Config` cannot tell a legacy install from an owner's own `features disable slack-digests` (both read `digest.enabled = false`), so the decision is made from the file, exactly as `MigrateFeatureGates` makes it: its two checks (`v.IsSet("features.migrated")`, and `v.IsSet("digest.enabled") && !v.GetBool("digest.enabled")`) move into a new read-only `config.FeatureMigrationPending(configPath) (pending, legacy bool, err error)`, which `MigrateFeatureGates` itself calls before writing, so both read the same rule. When `pending && legacy`, the command takes a value copy of the loaded config (the gates are value fields of value structs), runs the existing `config.ApplyLegacyDigestOff(&copy)` — already pinned to the on-disk migration by `TestApplyLegacyDigestOff_MatchesOnDiskMigration` — evaluates the features on the copy and adds `(not yet migrated)` to the line. Nothing is written. Tests `TestFeatureMigrationPending` (marker set → not pending; no marker + `digest.enabled: false` → legacy; no marker + digest true or absent → pending, not legacy; the file's bytes and mtime unchanged in every case) and `TestDiagnostics_FeaturesLegacyNotMigrated` (config unchanged, line shows the mapped state).
- **Recent errors.** The last 20 `pipeline_runs` rows with `status = 'error'` (time = `finished_at` in UTC, phase = `pipeline`, class), plus the last sync result in `last_sync.json` when it failed (phase `sync`). Never the text. No rows and no failed sync: `Recent errors: none`.
- **Error classes.** `diagnostics.ErrorClass(msg string) string` in a new `internal/diagnostics` package. Checks run in this fixed order on the lower-cased message; the first match wins:
  1. `cancelled` — `context canceled`
  2. `timeout` — `deadline exceeded`, `timed out`, `timeout`
  3. `rate_limit` — `rate limit`, `ratelimited`, `rate_limited`, `rate-limited`, `too many requests`, HTTP 429 in a status form (`status 429`, `http 429`, `status code: 429`, `429 too many`)
  4. `quota` — `usage limit`, `quota`, `insufficient credit`
  5. `auth` — `invalid_auth`, `not_authed`, `token_expired`, `token revoked`, `invalid_grant`, `authentication_error`, `invalid api key`, `unauthorized`, `forbidden`, HTTP 401/403 in a status form
  6. `not_found` — HTTP 404 in a status form, `not_found`
  7. `network` — `connection refused`, `no such host`, `network is unreachable`, `no route to host`, `connection reset`, `broken pipe`, `unexpected eof`
  8. `parse` — `unmarshal`, `invalid character`, `unexpected end of json`
  9. `other` — everything else.

  A bare number never matches (a status form is `(status|http|status code|error)[ :=]*NNN`, e.g. `googleapi: Error 401:`, or `NNN <reason phrase>`). Unknown wordings fall to `other`. Table test `TestErrorClass`: each class, an id-like `…401…` that is not a status (→ `other`), and an order case (`timeout` + `401` → `timeout`).
- **Crash.** Streams, line by line, `watchtower.log.1`, `watchtower.log` and `daemon.log` (each scanned whole, under one 2 s budget for all three; current files are ≤ 20 MiB, an old unbounded `daemon.log` is the reason for the budget). A crash is a line that **starts** with `panic: ` or `fatal error: ` (no timestamp prefix, so a logged "panic:" inside a message never counts) followed within 5 lines by a `goroutine <n> [` header; a `runtime stack:` line inside that window extends it up to the goroutine header that follows (a `fatal error: unexpected signal` from cgo/SQLCipher prints the runtime frames first — ask #1168). Test `TestDiagnostics_CrashRuntimeStack`. Its time is the timestamp of the nearest preceding timestamped line in the same file ("after" that time); none → `time unknown`. Log lines carry local time without a zone (`log.LstdFlags`, `2006/01/02 15:04:05`); the scanner parses them with `time.ParseInLocation(…, time.Local)` and prints UTC (`HH:mmZ`), like Recent errors. A local time in a DST gap or overlap takes `ParseInLocation`'s choice. Test `TestDiagnostics_CrashTimeLocalToUTC` (fixed `time.Local`, e.g. a +03:00 zone, plus a DST-overlap case). Its place (`<place>`) is the function of the first frame line in that goroutine trace starting with `watchtower/` (e.g. `watchtower/internal/sync.(*Syncer).run`); when the trace has none (a crash inside the Go runtime or a library) the place is `location unknown`. Every variant names the place, so the line is always `…, in <function>` or `…, in location unknown`. The newest is chosen by that time; ties and unknown times by file order — `watchtower.log` (newest), then `watchtower.log.1`, then `daemon.log`. Budget exhausted: the line ends with `(scan stopped after <N> MB)`. The panic message is never printed.
- **Never printed:** workspace name, account/team/site names and domains, emails, ids, channel/project/space names, Quick Connection and automation names, paths, raw flavor, model output, error text, log lines.
- **Partial output.** Each part is computed on its own; a failing reader prints `unknown (<reason>)` in its place and the command still exits 0.

| Line / part | No config (`Config: none (not set up)` or `unreadable (…)`) | Config ok, database missing / busy / not readable |
|---|---|---|
| Watchtower, macOS | printed | printed |
| AI | per table **AI line by config state** | printed (no database used) |
| Features | `unknown (no config)` (`unknown (no home directory)` when that is the reason) | printed (no database used) |
| Sources: account kinds, Quick Connections | `unknown (no config)` | `unknown (no database)` / `unknown (database busy)` |
| Sources: iPhone companion | printed (from `--iphone`) | printed |
| Daemon (pid file, `last_sync.json`) | `unknown (no config)` (both live in the workspace) | printed |
| Recent errors: pipeline runs | `unknown (no config)` | `pipeline runs unknown (…)` |
| Recent errors: sync row | `unknown (no config)` | printed from `last_sync.json` |
| Crash, Logs | `unknown (no config)` (the log files live in the workspace) | printed |
| Database: schema | `unknown (no config)` | `schema unknown (…)` |
| Database: file size | `unknown (no config)` | printed (`os.Stat`), left out when the file is missing |
| Database: managed by organization | printed (policy, not config) | printed |

### Inputs, and what each does when it fails

**Paths without a fatal helper.** `config.WorkspaceDir()` (and `DBPath()`, built on it) calls `log.Fatalf` when the home directory cannot be determined, which would break "always exit 0". The command never calls them: it resolves `root, err := config.DataRoot()` (returns the error) and joins `root/<ActiveWorkspace>` itself. The config path is `flagConfig`; `defaultConfigPath()` returns `""` when there is no home directory and no `WATCHTOWER_CONFIG_PATH`. Outcomes:
- **Precedence, one rule.** Resolution runs in this order and stops at the first failure: (1) config path, (2) config load, (3) data root, (4) workspace. The first failing step prints its own line and every line that depends on it prints `unknown (<that reason>)`; later steps are not tried and print no line of their own. So an empty HOME prints exactly one of two outcomes:
  - no `WATCHTOWER_CONFIG_PATH` (`flagConfig == ""`, step 1) → `Config: unknown (no home directory)`, no `Workspace:` line, and AI, Features, Sources (kinds, Quick Connections), Daemon, Recent errors, Crash, Logs and Database schema/size `unknown (no home directory)`;
  - `WATCHTOWER_CONFIG_PATH` set, config loads (step 3 fails) → `Config: ok`, AI and Features printed, `Workspace: unknown (no home directory)`, and the workspace lines `unknown (no home directory)`.

  In both, Watchtower/macOS, `iPhone companion` (from `--iphone`) and `managed by organization` print, and the command exits 0. Test `no_home_dir` asserts the first outcome's full text exactly (golden), and `no_home_dir_config_path_set` the second.
- **One name check for flag and config.** Like every command that reads it (`cmd/ask.go`, `cmd/ai.go`, `cmd/ai_session.go`, `cmd/ai_routing_status.go`: `if flagWorkspace != "" { cfg.ActiveWorkspace = flagWorkspace }` right after `config.Load`), diagnostics applies the global `--workspace` flag over `active_workspace`. Whichever name results — from the flag, from `active_workspace` in the config (a typo, or a deleted folder), or picked by `resolveActiveWorkspace` — goes through the same check, and is never printed: failing `config.ValidWorkspaceRe` → `Workspace: unknown (invalid name)`; valid but no `<root>/<name>` folder → `Workspace: unknown (not found)`; both replace the workspace lines like any `Workspace:` line (`config.Load` itself checks neither). Tests `workspace_flag_wins` (flag names the second of two workspaces; its counts are reported), `workspace_flag_invalid`, `workspace_flag_not_found`, `workspace_config_invalid_name`, `workspace_config_not_found` (DIAG-01's guard puts a canary in both the flag value and `active_workspace`).
- Config loaded but `ActiveWorkspace` empty (`config.Load`'s `resolveActiveWorkspace` picks the only workspace holding a database, and leaves it empty when there are none or several): the command counts `config.WorkspaceDirsWithDatabase(root)` itself and prints `Workspace: not chosen (<n> found)` for several, `Workspace: none yet` for none, `Workspace: unknown (lookup failed)` when the scan fails — never the names (they can be company names). An `ActiveWorkspace` failing `config.ValidWorkspaceRe` → `Workspace: unknown (invalid name)`.
- Whenever the `Workspace:` line is printed, it replaces the workspace lines — Sources (account kinds, Quick Connections), Daemon, Recent errors, Crash, Logs and the schema/size parts of Database — which each print `unknown (no workspace)`; the iPhone and policy parts still print. So a several-workspace install never shows a misleading `Daemon: stopped` or `unknown (no database)` from the data root.
- Tests (`TestDiagnostics_InputFailures` cases): `no_home_dir` (HOME unset, exit 0, no fatal), `workspace_not_chosen` (two workspaces with databases, line says `(2 found)`, no names), `workspace_none_yet`, `workspace_lookup_failed`, `workspace_invalid_name`.

Every line is built by its own function run through `safeLine`, which recovers a panic and prints `unknown (internal error)` for that line only. No input runs an external program: verified 2026-11-04 that `internal/config`, `internal/providers`, `internal/features` and `internal/policy` contain no `exec.Command`/`exec.LookPath`; the provider line reads config fields only and never resolves models by calling a CLI.

| Input | What it reads | Missing / failed / slow → printed text | Test |
|---|---|---|---|
| Build info | `cmd.Version`, `Commit`, `BuildFlavor` (→ `default`/`corp`), `--app-version` | cannot fail; no `--app-version` (terminal) → the `· app …` part is left out | `TestDiagnostics_VersionLine` |
| macOS, chip | `unix.Sysctl("kern.osproductversion")`, `unix.Sysctl("machdep.cpu.brand_string")` (syscalls) | error → `macOS unknown` / chip `Other` (the form's option) | `TestDiagnostics_SysctlFailure` (seam) |
| Config | `os.Stat(flagConfig)`, then `config.Load(flagConfig)` | not-exist (from `os.Stat`) → `Config: none (not set up)`; parse error → `unreadable (parse)`; permission → `unreadable (permission)`; a value `AIConfig.Validate` rejects (an unknown `ai.provider`, an unknown provider bucket or fallback) → `unreadable (invalid value)` — `config.Load` fails on it, as it does for every command; else `unreadable (other)`. The error text is never printed. To tell invalid values apart, `AIConfig.Validate` returns its errors as a new `*config.InvalidValueError` whose `Error()` is the current message unchanged (existing callers see the same text). Config-dependent lines then per the table above | `TestDiagnostics_NoConfig`, `TestDiagnostics_BrokenConfig`, `TestDiagnostics_UnreadableConfig` |
| Workspace | `config.DataRoot()`, `--workspace` / `active_workspace` / `resolveActiveWorkspace`, `config.ValidWorkspaceRe`, `config.WorkspaceDirsWithDatabase(root)` (see "Paths without a fatal helper") | `Workspace: not chosen (<n> found)` / `none yet` / `unknown (invalid name\|not found\|lookup failed\|no home directory)`, replacing the workspace lines; no line when a workspace resolves | `TestDiagnostics_InputFailures` cases `workspace_not_chosen`, `workspace_none_yet`, `workspace_lookup_failed`, `workspace_flag_wins`, `workspace_flag_invalid`, `workspace_flag_not_found`, `workspace_config_invalid_name`, `workspace_config_not_found`, `no_home_dir_config_path_set` |
| AI provider | The same resolution the app uses: `config.Load` reads `ai.provider` through viper with `SetEnvPrefix("WATCHTOWER")` + `AutomaticEnv()` + the `.`→`_` replacer (`config.go:603–605`), so `WATCHTOWER_AI_PROVIDER` overrides the file, which overrides the `claude` default (`SetDefault`, `config.go:479`); `Load` snapshots that into `AI.ConfiguredProvider` (`config.go:617`), and `ConfiguredProviderID()` (`config.go:81`) is what `Validate` and routing read. Empty (`ai.provider: ""` or an empty env var) is `claude` (`ai_routing.go:13`, `internal/providers/config.go:22`). `--provider` is not applied. Origin: `os.Getenv("WATCHTOWER_AI_PROVIDER") != ""` → environment; else a fresh viper read of the file with `v.InConfig("ai.provider")` and a non-empty value → chosen; else default. Mapped to `claude`/`codex`/`ollama`/`unknown` before printing | per table **AI line by config state** | `TestDiagnostics_AILine` cases `provider_absent_default`, `provider_empty_string`, `provider_claude_set`, `provider_codex`, `provider_ollama`, `provider_env_only`, `provider_env_overrides_file`, `provider_unknown_value` |
| AI fallback and buckets | `cfg.AI.Fallback.Enabled`, `cfg.AI.Fallback.Provider` (`config.go:36`), the keys of `cfg.AI.Providers`; on a config `Validate` rejected, the same keys from the raw read | the reserve part: `reserve <Name>, automatic` / `reserve <Name>, off` / no reserve → part left out; an invalid reserve or bucket per table **AI line by config state** | `TestDiagnostics_AILine` cases `reserve_automatic`, `reserve_off`, `reserve_none`, `fallback_unknown`, `fallback_same_as_preferred`, `fallback_not_a_pair` (ollama reserve), `fallback_enabled_without_pair`, `bucket_unknown` |
| Features | `features.All()` + config, as `features list` does (no database, no migration; legacy view in memory) | cannot block; a panic → `unknown (internal error)`; legacy unmigrated → `(not yet migrated)` suffix | `TestDiagnostics_FeaturesLine`, `TestDiagnostics_FeaturesLegacyNotMigrated` |
| Accounts | own `QueryContext` aggregates over the account tables in the Sources mapping | no database / deadline / not readable → the parts in the partial-output table; a missing table (older schema) → that kind `unknown` while the others print; unknown status → `<k> unknown state` | `TestDiagnostics_SourcesLine`, `TestDiagnostics_SourcesMissingTable`, `TestDiagnostics_AccountTablesMapped` |
| Quick Connections | own `QueryContext`: `SELECT count(*) FROM external_connections WHERE enabled = 1` | `Quick Connections <n>`; table missing (older schema) → `Quick Connections unknown`; no database / deadline → covered by the Sources part (`unknown (no database)` / `unknown (database busy)`) | `TestDiagnostics_InputFailures` cases `quick_connections_count`, `quick_connections_missing_table` |
| iPhone companion | `--iphone on|off`, passed by the Desktop, which owns the flag (`mobileSyncEnabled` in its own defaults — Go cannot read it) | absent (terminal) → the part is left out. **So the terminal's text and the app's text differ by exactly this one part**: only the app knows the setting, and guessing it in Go would mean reading another app's defaults | `TestDiagnostics_IPhoneFlag` |
| Policy | `policy.Current()` → `Policy{Managed, Errors}`: the cgo CoreFoundation reader `main` installs (local, cached 30 s). It returns no error and has no unknown state | `Managed = false` → `no`; `Managed = true`, no `Errors` → `yes`; `Managed = true` with `Errors` (a forced key of the wrong type, applied most-restrictive) → `yes (with errors)`. A build without the darwin reader (Linux CI) reads an empty map and prints `no` — not reachable in the shipped app | `TestDiagnostics_PolicyLine` (`policytest.Set`: unmanaged, managed, managed with a defect) |
| Daemon | `daemon.PeekProcess(<workspace>/daemon.pid)` → `(pid, state, err)` with an exported state `PeekNone`/`PeekRunning`/`PeekGone`/`PeekReused`/`PeekUnknown` mirroring `resolveProcess` (file read + signal 0 + start-time identity check, never removes a file); `<workspace>/last_sync.json` (read + parse) | first part, exactly: no pid file → `Daemon: stopped`; `PeekGone`/`PeekReused` (dead pid, a pid reused by another process, or an untagged file older than 30 days) → `Daemon: stopped (stale pid file)`; `PeekRunning` → `Daemon: running`; `PeekUnknown` (live pid, identity read failed) → `Daemon: unknown (process not confirmed)`; empty or unparsable file (`ReadPID`'s `parsing pid file` errors) → `Daemon: unknown (pid file corrupt)`; read error with `fs.ErrPermission` → `Daemon: unknown (pid file unreadable: permission)`; any other read error → `Daemon: unknown (pid file unreadable: other)`. Second part: `last cycle <age> ago, done|error|running`; `last_sync.json` missing → `no cycle yet`; unparsable or unreadable → `last cycle unknown` | `TestDiagnostics_DaemonLine` cases `no_pid_file`, `stale_dead_pid`, `reused_pid`, `old_untagged`, `running_confirmed`, `identity_unknown`, `empty_file`, `garbage_file`, `permission_denied`, `last_sync_missing`, `last_sync_corrupt`; `internal/daemon::TestPeekProcess_States` (one case per state, file never removed) |
| Recent errors | own `QueryContext` on `pipeline_runs`, plus `last_sync.json` | no rows → `none`; no database / deadline → `unknown (no database)` / `unknown (database busy)` | `TestDiagnostics_RecentErrors`, busy tests below |
| Error class | `diagnostics.ErrorClass` (pure) | cannot fail; unknown wording → `other` | `TestErrorClass` |
| Schema, size | own `QueryContext`: `SELECT max(version_id) FROM goose_db_version`; `os.Stat` of the file | no goose table → `schema unknown`; deadline → `schema unknown (database busy)` while the size still prints; stat error → size left out | `TestDiagnostics_DatabaseLine`, `TestDiagnostics_BusyKeepsFileParts` |
| Database open / read | `db.OpenExistingContext`, then the reads | the database parts (Sources kinds and Quick Connections, pipeline runs, schema) print: file missing → `unknown (no database)`; `SQLITE_NOTADB` (not a database — also a SQLCipher-keyed file once #603 Stage 2 lands) → `unknown (database unreadable: not a database)`; `SQLITE_CORRUPT` → `unknown (database unreadable: corrupt)`; `SQLITE_CANTOPEN`/`SQLITE_PERM`/`SQLITE_READONLY` or `fs.ErrPermission` → `unknown (database unreadable: permission)`; the driver does not confirm `NO_CKPT_ON_CLOSE` (`out != 1`, the connect fails, nothing is read and nothing is retried without it) → `unknown (database not opened: checkpoint guard unavailable)`; any other open error → `unknown (database unreadable: other)`. The file-size part still prints whenever `os.Stat` works | `TestDiagnostics_InputFailures` cases `db_missing`, `db_not_a_database` (random bytes), `db_corrupt` (a valid header with a damaged page), `db_permission` (mode 000), `db_no_ckpt_guard` (connector seam returns `out = 0`), `db_other` |
| Log sizes | `os.Stat` of `watchtower.log`, `daemon.log` | missing → `<file> missing`; other error → `<file> unreadable` | `TestDiagnostics_LogMissing`, `TestDiagnostics_LogUnreadable` |
| Crash | streamed reads of `watchtower.log.1`, `watchtower.log`, `daemon.log` | file missing/unreadable → skipped; all three → `Crash: unknown (no logs)`; 2 s budget hit → `(scan stopped after <N> MB)` | crash tests in Failure modes |
| Any input | — | panic → `unknown (internal error)`; still running at the 8 s hard stop → `unknown (timed out)` | `TestDiagnostics_LinePanicIsContained`, `TestDiagnostics_HardStop` |
| `last_sync.json` (Recent errors sync row) | the same file as Daemon | missing → no sync row; unparsable → `  sync result unknown` | `TestDiagnostics_InputFailures` (`sync_row_*`) |

**AI line by config state** (the one definition; the partial-output table, the Failure modes table and the Inputs rows point here):

| Config line | AI line | JSON `provider` |
|---|---|---|
| `Config: ok` | `AI: <Claude Code\|Codex\|Ollama>` (chosen in the file), `… (from environment)`, or `AI: Claude Code (default, not chosen)`; then the reserve part | the form option of the effective provider (`Claude Code` for the default) |
| `Config: none (not set up)` | `AI: not set up (no config)` | `Not set up yet` |
| `Config: unreadable (invalid value)` — `Validate` rejected the AI section | from the raw read (fresh viper, same env rules), mapped: a known preferred provider prints as in the first row; an unknown one prints `AI: unknown (not a known provider)`. Then the part `Validate` rejected: `· reserve invalid` (unknown fallback, equal to the preferred, outside a Claude/Codex pair, or enabled without a pair) and/or `· provider settings invalid` (unknown bucket). No raw value is printed | a known preferred provider → its form option; an unknown one → `""` (dropdown left unset) |
| `Config: unreadable (parse\|permission\|other)` | `AI: unknown (no config)` | `""` |
| `Config: unknown (no home directory)` | `AI: unknown (no home directory)` | `""` |

Tests: the `TestDiagnostics_AILine` cases above plus `config_missing`, `config_parse_error`, `config_permission`, `no_home_dir`, each asserting the AI line and the JSON `provider` together.

### Time budget

The Desktop kills the command after 10 s (`CLIRunnerProtocol.run(args:timeout:)`), so the command must always finish well before that, however busy the database is. SQLite's `busy_timeout` applies per statement, and the command runs many statements, so a per-statement limit alone could add up past 10 s.

- **One database deadline.** All database work — the open's ping and every query — runs under one `context.WithTimeout` of **4 s**, started before the open. The busy timeout per statement is **500 ms**. When the deadline passes, the statement in flight and every database line not yet computed print `unknown (database busy)`; lines already computed stay.
- **How the deadline reaches SQLite (verified 2026-11-04).** `db.OpenExisting` calls `Ping()` with no context and opens `mode=rw`, and the existing read helpers take no context, so the command reuses none of them:
  - `internal/db/db.go`: `openExistingDSN(dbPath, dsn)` becomes `openExistingDSN(ctx, dbPath, dsn)` and calls `d.PingContext(ctx)` (the pool's `pragmaConnector.Connect(ctx)` already receives that context). New exported `OpenExistingContext(ctx, dbPath, busy)` = `OpenExisting`'s DSN through that path. `OpenExisting` and `OpenExistingRW` pass `context.Background()` — the same behaviour as today for every caller (grep on main `feb9c2054`, 2026-11-10): `cmd/workbench_asks_cli.go`, `cmd/workbench_spec_review.go`, `cmd/workbench_spec_review_thread.go`, `cmd/workbench_askguard.go` ×2, `cmd/workbench_askguard_stop.go` ×3 (two `OpenExisting`, one `OpenExistingRW`), `cmd/workbench_session_feed.go`, `cmd/usage_llm.go` (plus its `agentlogdb.OpenExisting`), `cmd/usage_plans.go` ×2 (one RW), `cmd/session_host_watch.go` (RW), `cmd/llmusage_wiring.go` (RW), `internal/agentlogdb/totals.go`, `internal/db/compact.go` ×2 (one RW), `internal/db/fts_rebuild.go` ×3 (one RW), `internal/hub/wiring.go`, `internal/hub/state/state.go`. Besides `openExistingDSN` and the new `OpenExistingContext`, the only other change in `internal/db` is the small `openExistingWith(ctx, dbPath, connector)` from the Seam below, which `OpenExistingContext` uses to pass its `NoCheckpointOnClose` connector; no existing function's behaviour changes.
  - The four reads (accounts, Quick Connections, `pipeline_runs`, goose version) are the command's own `QueryContext` calls in `internal/diagnostics/lines_db.go` (wired by `cmd/diagnostics.go`; there so they can be tested without the cobra command — plan deviation note); no shared helper gains a context parameter.
  - The driver honours the context: `internal/sqlcipher/sqlite3.go` runs a statement in a goroutine and calls `sqlite3_interrupt` on `ctx.Done()` (exec ~l.2481, rows ~l.2698). Its own comment says the interrupt is racy and can miss between `sqlite3_*` calls; the statement then finishes on its own, bounded by the 500 ms busy timeout plus the query's own time (small aggregate reads).
  - **Close** is inside the database stage and its budget; it never checkpoints (`NO_CKPT_ON_CLOSE`).
- **If a call ignores the context anyway**, the database stage runs in its own goroutine and the command stops waiting for it at 4.5 s: the lines it has not delivered print `unknown (database busy)` and the command goes on; the stranded goroutine dies with the process.
  - The database part therefore takes ≤ 4.5 s.
- **Log scan:** its own 2 s budget (above).
- **The rest** (process start, config, `sysctl`, policy read, pid file, `last_sync.json`, `stat` of logs and the database file): local, no network, no locks, no external programs, ≤ 0.5 s.
- **Total:** 0.5 + 4.5 + 2 = **7 s worst case**, leaving 3 s to the Desktop's 10 s for process launch and JSON decoding. The database and the log scan run one after the other (no shared lock, but sequential keeps the arithmetic simple and the CPU low).
- **Hard stop.** Whatever an input does (a hung local file read, a bug), the lines are built in a worker goroutine and the command prints what it has at **8 s** — missing lines `unknown (timed out)` — and exits 0, still inside the app's 10 s.

**Budget outputs.** What each budget prints when it runs out, and the partial-report marker:

| Budget runs out | Lines / parts affected, exact text | Marker | Test case (`TestDiagnostics_InputFailures`) |
|---|---|---|---|
| Database deadline (4 s, + 0.5 s fallback) | parts not yet computed: `Sources: unknown (database busy)` (iPhone part still printed), `  pipeline runs unknown (database busy)` (sync row still printed), `Database: schema unknown (database busy)` (size and policy still printed); parts already computed stay | `partial: true`; last line `Partial report: database busy` | `budget_db_before_open`, `budget_db_midway` |
| Log scan (2 s) | `Crash: … (scan stopped after <N> MB)` — the crashes found so far, or `Crash: none in the first <N> MB of the logs (scan stopped)` when none; Logs line unaffected (stat only) | `partial: true`; last line `Partial report: log scan stopped` | `budget_logscan_with_crash`, `budget_logscan_none_found` |
| Hard stop (8 s) | every line or part not finished: `unknown (timed out)` | `partial: true`; last line `Partial report: timed out at 8 s` | `budget_hard_stop` |

**`partial` is true when any budget ran out or any part printed `database busy` or `timed out`** — a single statement that waits its 500 ms `busy_timeout` and fails with `SQLITE_BUSY` before the 4 s deadline also prints `unknown (database busy)` for its part and sets `partial`. The last line names each reason once, comma-separated in table order (`Partial report: database busy, log scan stopped`). A complete report has no such line and `partial: false`. Test cases `busy_single_statement` (one held lock for one read only: that part busy, `partial: true`, `Partial report: database busy`) and `busy_and_logscan` (both reasons, in order). The Desktop shows a partial report as ready (the text explains itself), not as failed.

A busy database is real even in WAL mode: a writer holding `locking_mode = EXCLUSIVE`, or WAL recovery after a crash, makes readers wait. Test `TestDiagnostics_BusyDatabaseFinishesInTime`: another connection takes an exclusive lock (`PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE`) and holds it; the command finishes in under 5 s of database time and under 7.5 s total, exits 0, prints `unknown (database busy)` for Sources, Recent errors and Database, and every non-database line normally. A second test, `TestDiagnostics_DeadlineMidway`, uses a fake reader seam whose queries sleep 1.5 s each: the lines computed before the deadline are printed, the rest say `unknown (database busy)`, and the total stays under 7.5 s.

### The sheet

Help → **Report a Problem…** (after Watchtower User Guide) and **Report a Problem…** beside **Open Logs** in Settings → System → Logs open one sheet on the main window. Both entries always call `bringMainWindowForward()` first (activate + make key and order front, open the window if none), so the sheet never lands behind the Settings window or with no window at all. The style guide allows a sheet for a short one-field form.

Layout (see mockups): title, intro, **What happened?** field (≤ 2 000 characters), the diagnostics block exactly as it will be sent (monospaced, selectable, in a card), the public-issue note, a quiet **A question, not a problem? Ask in Discussions** link (`ReleaseLinks.repository/discussions`), and Cancel · **Save Diagnostics…** · **Open GitHub Issue** (the one prominent action). The buttons stack vertically when the sheet is narrow.

**Corporate build.** When `HubIdentity.bundleFlavor()` is `.corp`, the sheet shows the corp intro, no public note, no Discussions link and only Cancel · **Save Diagnostics…** (prominent). There is no GitHub form to ask for steps and expected behaviour, so the corp placeholder asks for all of them itself: `Steps to reproduce, what you expected, and what happened instead.` The intro names no recipient: the app does not know the company's support channel. Nothing points at the public tracker.

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
| corp intro | `This is your organization's build. Save the diagnostics to a file to share them.` |
| field | `What happened?` / placeholder `What you did, what you expected, what you saw instead.` / corp placeholder `Steps to reproduce, what you expected, and what happened instead.` / `Describe the problem to continue.` |
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
| Database missing | lines per the table above | Go `TestDiagnostics_NoDatabase` |
| Database not a database (random bytes, or a SQLCipher-keyed file) | database parts `unknown (database unreadable: not a database)`; size, policy, iPhone and every non-database line print; exit 0 | `TestDiagnostics_InputFailures/db_not_a_database` |
| Database corrupt | database parts `unknown (database unreadable: corrupt)`; the rest prints | `…/db_corrupt` |
| Database not readable (permission) | database parts `unknown (database unreadable: permission)`; the rest prints | `…/db_permission` |
| Checkpoint guard not confirmed by the driver | the connect fails, nothing is read, no retry without the guard; database parts `unknown (database not opened: checkpoint guard unavailable)` | `…/db_no_ckpt_guard` (connector seam reports `out = 0`) |
| Other open error | database parts `unknown (database unreadable: other)` | `…/db_other` |
| No home directory | the one precedence rule above; exit 0, no `log.Fatalf` | `…/no_home_dir`, `…/no_home_dir_config_path_set` |
| Workspace not resolvable (several, none, `--workspace` or `active_workspace` invalid or not found) | a `Workspace:` line replaces the workspace lines | `…/workspace_not_chosen`, `…/workspace_none_yet`, `…/workspace_flag_invalid`, `…/workspace_flag_not_found`, `…/workspace_config_invalid_name`, `…/workspace_config_not_found` |
| AI section invalid (unknown `ai.provider` in file or env, bad fallback, unknown bucket) | `Config: unreadable (invalid value)`; AI line and JSON `provider` per table **AI line by config state**; other config-dependent lines `unknown (no config)`; no raw value printed | `TestDiagnostics_AILine` cases `provider_unknown_value`, `fallback_unknown`, `fallback_same_as_preferred`, `fallback_not_a_pair`, `fallback_enabled_without_pair`, `bucket_unknown` |
| Database busy (held write lock, slow queries) | one 4 s database deadline + 500 ms per statement; unfinished database lines `unknown (database busy)`; the command ends in ≤ 7 s, inside the app's 10 s, so the report keeps every other line | Go `TestDiagnostics_BusyDatabaseFinishesInTime` (exclusive lock held by another connection; total < 7.5 s), `TestDiagnostics_DeadlineMidway` (fake slow reader); Swift `testBusyDatabaseLinesShown` (a CLI answer with `database busy` lines is shown as ready, not failed) |
| Log file missing / unreadable | `Logs:` says `missing` / `unreadable` for that file; the crash scan skips it | Go `TestDiagnostics_LogMissing`, `TestDiagnostics_LogUnreadable` |
| Large log | whole files streamed, 2 s budget, `(scan stopped after <N> MB)` when hit | Go `TestDiagnostics_PanicDeeperThan256KB` (panic at the start of a 5 MB file is found), `TestDiagnostics_ScanBudget` (injected clock) |
| Crash shapes | `panic:`/`fatal error:` + `goroutine` header counted; a timestamped log line containing `panic:` not; time from the preceding timestamped line or `last time unknown`; place = first `watchtower/` frame or `location unknown`; newest by time, then file order | Go `TestDiagnostics_CrashRuntimeHeaders`, `TestDiagnostics_IgnoresLoggedPanicText`, `TestDiagnostics_CrashTimeAndPlace` (time known + place), `TestDiagnostics_CrashTimeUnknownWithPlace` (no preceding timestamp), `TestDiagnostics_CrashLocationUnknown` (runtime-only trace, time known), `TestDiagnostics_CrashTimeAndLocationUnknown`, `TestDiagnostics_NoCrash` (`none in the logs`), `TestDiagnostics_CrashOrderAcrossFiles` |
| URL too long (incl. Cyrillic, CJK) | steps 2–3 + too-long notice | `ReportProblemLinkTests` (above) |
| Browser does not open | notice + Copy Link; sheet stays | `testBrowserFailureOffersCopyLink` |
| GitHub errors after the browser opened | sheet still open with the text; Open again | `testSheetStaysOpenAfterOpen` |
| No main window / Settings in front | main window fronted, then the sheet | `testMenuFrontsMainWindow` (no window), `testSettingsEntryFrontsVisibleMainWindow` (visible main window behind Settings: `activate` and `makeKeyAndOrderFront` called before presenting; injected windows/activate) |
| User closes mid-way | task cancelled, child terminated, nothing written | `testCancelWhileCollectingTerminates` |
| Save fails | inline notice with the reason, atomic write leaves nothing partial | `testSaveFailureShowsReason` |
| Corp build | no GitHub, no Discussions; Save only | `testCorpBuildOffersSaveOnly` |

**Writers.** None of this data has a writer: the command and the sheet write no Watchtower data and never the main database file. Per Decision 15, the only file effects are SQLite's own: the `-shm` read marks / wal-index, and on a cleanly stopped install a new empty `-wal` + `-shm` pair that stays until the next normal open. The sheet's only writes are the user-chosen file and the pasteboard, each once per user press.

## Paths that change together

- `bug_report.yml` field ids and dropdown option labels ↔ `ReportProblemLink` keys ↔ the Go `chip`/`provider`/`sources` mappings. Go `TestDiagnostics_FormOptions` parses `.github/ISSUE_TEMPLATE/bug_report.yml` and checks every value the mapping can emit is an option — for `sources`, every form-mapped kind is a checkbox label and every checkbox label has a kind, with an explicit skip list of the kinds that have no checkbox (CalDAV/ICS calendars, Quick Connections); Swift `testLinkKeysMatchForm` checks the keys against the same file's ids.
- CLI start-up: `diagnostics` joins the no-op `PersistentPreRunE` commands and the `sweepStaleTemp` skip in `Execute()`; a change to `ensureSchemaFormat`, `Execute()` or `OpenExisting`'s lock-metrics wiring must keep `TestDiagnostics_WritesNothing` green.
- Desktop arguments: the sheet runs `watchtower diagnostics --json --app-version <CFBundleShortVersionString> --iphone <on|off from mobileSyncEnabled and the policy's MobileSync>`; Swift `testDiagnosticsArguments` pins them.
- `internal/db.OpenExistingContext` ↔ `OpenExisting`/`OpenExistingRW` share the DSN and the ping path; their callers keep `context.Background()` and the default close.
- `sqlcipher.Connector.NoCheckpointOnClose` is set by `OpenExistingContext` only; a driver or SQLite upgrade must keep `TestConnector_NoCheckpointOnClose` and `TestDiagnostics_LeftOverWALMainFileUntouched` green.
- `daemon.PeekProcess` ↔ `FindProcess` share `resolveProcess(path, removeStale)`; only `PeekProcess` passes `false`.
- Sources mapping ↔ the account tables and their `status` values in `schema.sql`; a new `*_accounts` table fails `TestDiagnostics_AccountTablesMapped`.
- Features ↔ `config.MigrateFeatureGates` through the shared read-only `config.FeatureMigrationPending` and the existing `config.ApplyLegacyDigestOff` (FEAT-01's migration stays the only writer of `features.migrated`).
- Corp rule: Go's `flavor` output (`""`/`dev` → `default`, else `corp`) ↔ Swift `HubIdentity.flavor(buildFlavor:)`, which the sheet uses directly (it must decide even when the CLI failed). Pinned on both sides by a shared case table `report_problem_flavor_cases.json`.
- Crash scan ↔ `cmd/logfile.go` (where the daemon's stderr lands, rotation name `.1`, the log timestamp layout) and the Go runtime's crash header.
- `ErrorClass` markers ↔ provider error wording.

## Privacy

- What leaves the Mac: only what the user sees in the sheet and submits on GitHub in their browser, or a file they saved and send themselves. No network call by the app.
- The diagnostics carry kinds, counts, states, error classes, sizes, versions, dates and `default`/`corp`; never anything on the never-printed list.
- **Guard DIAG-01:** `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText` seeds a database, a config and log files with `logcanary.Marker` canaries in every name and text field the command reads around (workspace name in `active_workspace` and in `--workspace`, `ai.provider` in the file and in `WATCHTOWER_AI_PROVIDER` (an unknown value), account names, team domains, emails, channel/space/project names, Quick Connection and automation names, `pipeline_runs.error_msg`, account status text, `last_sync.json` error, a panic message in `watchtower.log`, `BuildFlavor`) and asserts neither the text nor the JSON contains the marker, a `/Users/` path or an `<acct>:<id>` shape. Swift `testReportCarriesOnlyCLITextAndUserText`.
- The user's own text is theirs: the sheet says the issue is public; the app does not scan it.

## Decisions

| # | Decision | Source |
|---|---|---|
| 1 | No telemetry, no crash service; the report is user-initiated and the app sends nothing | ask #996 |
| 2 | Build Report a Problem now | ask #1023 |
| 2a | The full feature (CLI, sheet, guard), not a minimal version | ask #1029 |
| 3 | Go `watchtower diagnostics` is the one source; the Desktop shows its text verbatim | ask #1026 |
| 4 | Errors are reported as the last 20 failures, class + phase + time, no text and no log lines | ask #1026 |
| 5 | GitHub only in v1: no email or other channel for people without GitHub | ask #1026 |
| 6 | Corporate builds: Save Diagnostics only, no GitHub, no Discussions | ask #1026 |
| 7 | New inventory entry DIAG-01 with its guard | ask #1026 |
| 8 | Discussions link in the sheet for questions | decided by agent (target #1527 names Discussions) |
| 9 | One user field. On GitHub, Steps and Expected stay on the form: it requires and shows them anyway, so more fields in the sheet would duplicate it; the GitHub link carries the text whole unless the budget's step 3 cuts it (then Copy Report has it whole). In a corp build there is no form, so the corp placeholder asks for steps, expected and actual itself, and Save writes the text whole | decided by agent |
| 10 | On CLI failure the Desktop adds macOS from `ProcessInfo` (a one-line read, no mapping); the chip is left for the user (one click on the form) because mapping it in Swift would duplicate Go's table | decided by agent |
| 11 | Crash: runtime headers only, time from the preceding log line, place = first `watchtower/` frame or `location unknown` in every variant, whole-file streaming scan under a 2 s budget, newest by time then file order | decided by agent |
| 12 | Budget on the encoded URL (6 000), three-step shortening, 2 000-character field cap | decided by agent |
| 13 | Clipboard written only by explicit Copy buttons | decided by agent |
| 14 | The sheet stays open after Open and keeps the text until Done; nothing kept after it closes | decided by agent |
| 15 | The command never writes the main database file and writes none of Watchtower's files: no pre-run, no temp sweep (`shouldSweepTemp`), no features migration, no stale-pid cleanup (`PeekProcess`), lock-metrics sink off; the database opened with `OpenExistingContext` (`mode=rw` + `query_only`, `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`, `wal_autocheckpoint = 0`). The only files that may change are SQLite's `-shm` (read marks, wal-index) and, on a cleanly stopped install, a new empty `-wal`/`-shm` pair — measured in two experiments | ask #1033 (main file never written); the opener and the measurements decided by agent |
| 16 | Entry points: Help menu, and Settings → System → Logs because that is where someone looking at logs after a failure already is; both always front the main window; no About link, no toolbar button | decided by agent |
| 17 | Only `default`/`corp` is printed, never the raw flavor (it can name the company) | decided by agent |
| 18 | Screenshots and videos are not part of the report (the form's own hint covers them) | decided by agent |
| 19 | The Settings → Logs "Crash Log" tab rename is not part of this feature (a separate UI change the owner has not approved); see Follow-ups | decided by agent |
| 20 | Error classifier: fixed order, HTTP codes only in a status form, unknown wordings → `other` | decided by agent |
| 21 | One 4 s deadline for all database reads with a 500 ms per-statement busy timeout (new `db.OpenExistingContext` + the command's own `QueryContext` reads, a 4.5 s stop-waiting fallback), a 2 s log-scan budget, 7 s worst case and an 8 s hard stop inside the app's 10 s | ask #1028 (owner asked for one overall budget; the numbers decided by agent) |
| 22 | Every crash variant names its place; no `watchtower/` frame → `location unknown` | ask #1028 |
| 23 | Per-input failure behaviour, a panic contained per line, no input runs an external program; the iPhone flag comes from the Desktop as `--iphone` | ask #1030 (owner asked for the coverage; the specifics decided by agent) |
| 24 | CLI audit: `diagnostics` is decided as a **no-content** command — it joins `cliNoContentCommands` in `cmd/audit_cli_test.go` (next to `policy show`, `version`) with the comment "kinds, counts, states and error classes only (DIAG-01)", so it writes **no** `com.watchtower.audit` line, under an agent marker or not. It prints no synced content (DIAG-01's guard proves it), so READ-02's "every company-data read leaves one line" does not apply; READ-01's budget is for registry read tools and the command is not one (no MCP tool is added) | ask #1039 |
| 25 | Under an agent marker (`CLAUDECODE`, `CODEX_*`, `WATCHTOWER_TERMINAL_SESSION_ID`, `WATCHTOWER_AUTOMATION_RUN_ID`) the command runs as usual — it is not an owner gesture, writes nothing and shows no content, so AGENT-07's `refuseUnderAgent` list does not grow | ask #1039 |
| 26 | Daemon line texts for every `PeekProcess` state and pid-file error, and the budget outputs | ask #1034 (owner asked for them; the texts decided by agent) |
| 27 | The pinned JSON key `partial` and the `Partial report: <reasons>` last line; `partial` = any budget ran out or any part busy/timed out | ask #1043 |
| 28 | Open GitHub Issue is disabled while "What happened?" is empty, in every state | ask #1043 |
| 29 | Paths resolved without `WorkspaceDir`/`DBPath` (no `log.Fatalf`); a `Workspace:` line replaces the workspace lines when none resolves, with a count and never names | decided by agent |
| 30 | Unreadable-database texts per SQLite error class; no read without the checkpoint guard | decided by agent |
| 31 | Outlook accounts shown on their own in the text and mapped to the form's `Email over IMAP` checkbox | ask #1043 |
| 32 | The global `--workspace` flag wins over `active_workspace`, as in `ask`/`ai`/`ai session`; an invalid or unknown name — from the flag or from the config — gives a `Workspace:` line, never the name | decided by agent; the config half by ask #1045 |
| 33 | AI line: the app's own resolution (env > file > `claude` default, empty = `claude`); JSON `provider` is always the effective provider (`Claude Code` for the default); the text notes `(default, not chosen)` or `(from environment)`; the value is mapped to a closed list and an unknown one is never printed; `AIConfig.Validate` errors become a typed `InvalidValueError` with the same message | ask #1045 (owner's three points); the mechanism decided by agent |
| 34 | Crash window extended by `runtime stack:`; error-class markers widened with our providers' real spellings (Slack, Google, Claude, network) and the `Error NNN:` status form | ask #1168 |

### Contracts touched

| Contract | How it is affected | Guard test |
|---|---|---|
| **DIAG-01** (new, `docs/inventory/diagnostics.md`) | **New**: the diagnostics carry kinds, counts, states and classes only; plus the pinned `--json` keys `text`, `version`, `macos`, `chip`, `provider`, `sources`, `flavor` (approved in ask #1026), and `partial` (**ask #1043**) | `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText`, `TestDiagnosticsText_Pinned` |
| **READ-02** (audit line per company-data read, `agent-actions.md`) | **Extended by classification only**: `diagnostics` is added to `cliNoContentCommands`; no audit line (decision 24); the contract's behaviour is unchanged | `cmd/audit_cli_test.go::TestCLIAudit_EveryCommandIsDecided`, `TestCLIAudit_OnlyContentCommands` |
| **READ-01** (read budget) | **Unchanged**: no registry read tool is added | `internal/tools` registry guard (`UndecidedReadTools`) unchanged |
| **AGENT-07** (only the owner approves; `refuseUnderAgent`) | **Unchanged**: diagnostics is not added to the refused list (decision 25) | existing AGENT-07 tests |
| **AGENT-01..06, DEV-01..06** | **Unchanged**: no MCP tool, no surface, no write | existing guards |
| **FILES-01** (logs carry no names or text) | **Unchanged, relied on**: no log line ever leaves; decision 4 rests on what FILES-01 leaves in logs (`<acct>:<id>`) | the FILES-01 guards in `files.md` |
| **FEAT-01** (incl. "One write from a read command") | **Unchanged, relied on**: diagnostics never writes `features.migrated`; `MigrateFeatureGates` now calls the extracted read-only `FeatureMigrationPending`, same behaviour | `internal/config/feature_migrate_test.go` (all, incl. `TestApplyLegacyDigestOff_MatchesOnDiskMigration`), new `TestFeatureMigrationPending` |
| **POLICY-01..03** | **Unchanged, relied on**: reads `policy.Current()` only; no source guard needed (the command is not a source command and reads no source) | `internal/policy` tests unchanged |
| **SEARCHIDX-01 / db compact** | **Unchanged**: `compact.go`/`fts_rebuild.go` keep `OpenExisting`/`OpenExistingRW` with `context.Background()` | `TestCompact_PreservesRowids` and the compact tests |
| **LLMUSAGE-01** | **N/A**: no model call, no process start, no HTTP | `TestLLMUSAGE01_LeavesRecord` unchanged |
| **PROJ-***, **AUTO-***, **PURGE-***, **BACKUP-01**, **MEETPRIV-*** | **N/A**: no workbench, automation, purge, backup or meeting path touched | — |

## Mockups

Real SwiftUI shots from `DesignShotCatalog` (`ReportProblemShotFixtures` in `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+ReportProblem.swift`, design-only, sample data only). The PNGs are committed on branch `feat/1527-report-problem` under `docs/design/mockups/report-a-problem/`, each in `-light.png` and `-dark.png`:

| Shot | Shows |
|---|---|
| `report-problem-collecting` | loading/busy: empty field, spinner + "Collecting diagnostics…", Save and Open disabled |
| `report-problem-empty` | ready, nothing typed: full diagnostics, "Describe the problem to continue.", Open disabled |
| `report-problem-filled` | ready, typed: full diagnostics, Discussions link, Cancel · Save Diagnostics… · Open GitHub Issue |
| `report-problem-busy` | database busy: `Sources: unknown (database busy) · iPhone companion on`, `pipeline runs unknown (database busy)` with the sync row under it, `Database: schema unknown (database busy) · 1.2 GB · managed by organization: no`, and the last line `Partial report: database busy`; every other line normal, sheet ready |
| `report-problem-failed` | error: warning with the 10-second reason, partial lines (app and macOS versions), Retry; Open enabled because text is typed |
| `report-problem-opened` | after Open: green "Opened in your browser…" notice, Cancel became Done |
| `report-problem-tooLong` | after Open over budget: warning "did not fit in the link" + Copy Report, Done |
| `report-problem-browserFailed` | browser did not open: warning + Copy Link, Done |
| `report-problem-saveFailed` | save failed: warning with the reason, buttons unchanged |
| `report-problem-corp` | corporate build: corp intro "Save the diagnostics to a file to share them.", `flavor: corp`, `managed by organization: yes`, no public note, no Discussions, Cancel · Save Diagnostics… (prominent) |
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
- `docs/daemon-pipeline.md`: its data-paths table gains `watchtower diagnostics` as a reader of `watchtower.log`/`.1`/`daemon.log`, `daemon.pid`, `last_sync.json` and the database (read-only), and states where panics land.
- `docs/inventory/agent-actions.md` (where READ-02 lives): a changelog line — `diagnostics` decided as a no-content CLI command (`cliNoContentCommands`, decision 24), READ-02 unchanged — and `cmd/audit_cli_test.go` gains the entry.
- Inventory: a new `docs/inventory/diagnostics.md` with DIAG-01 (Enforced, guard `cmd/diagnostics_test.go::TestDIAG01_NoNamesOrText`, approved in ask #1026) and a row in `docs/inventory/README.md`: Diagnostics → `diagnostics.md` → `cmd/diagnostics.go`, `internal/diagnostics/`, `WatchtowerDesktop/Sources/WatchtowerCore/` (`ReportProblem*`).
- Feature note `docs/features/report-a-problem.md` + CLAUDE.md index line.

## Follow-ups (not in this feature)

- Settings → Logs "Crash Log" tab and caption are stale (panics land in the Sync Log since the stderr redirect); rename it as its own change once the owner agrees.
