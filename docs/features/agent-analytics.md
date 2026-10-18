# Agent analytics — ingest core (2026-10-15) and history analytics (2026-10-16)

Board #296 (initiative), #297 (ingest core), #298 (history analytics, the sections from "Parser v2" on). Specs: `docs/superpowers/specs/2026-10-15-agent-analytics-core-design.md`, `docs/superpowers/specs/2026-10-16-agent-analytics-history-design.md`; plans in `docs/superpowers/plans/`. Contracts: `docs/inventory/agent-analytics.md`.

## Purpose and the #296 roadmap

Turn analytics on for a workbench and see the history of every agent session run in its folder: tokens, cost, tools, skills, errors, denials, interruptions. #297 builds the ingest core: it reads the agent's own transcripts, writes normalized rows into the shared SQLite and keeps them current. #298 turns those rows into answers to "why is agent work slow and expensive": a time breakdown, tasks, subagent parallelism, cost, rule-based hints and an Analytics pane.

| # | Sub-project | Order |
|---|---|---|
| #297 | Ingest core, Claude Code first (Codex is its follow-up step) | 1 |
| #298 | History analytics: time model, tasks, hints, Analytics pane, session timeline (shipped; commit linking beyond `pr_link` not built) | 2 |
| #299 | Skill lab: with/without-skill evals, trigger precision/recall | 3 |
| #300 | Debug mode: OTel, verbose capture, LLM judge | 4 |

## Data source

Claude Code writes `~/.claude/projects/<slug>/<session-uuid>.jsonl`; subagents write `<slug>/<session-uuid>/subagents/agent-*.jsonl`. The slug is the cwd with every non-alphanumeric character replaced by `-` (lossy, so only a prefilter). For a workbench folder `F` the candidate directories are those named `slug(F)` or starting with `slug(F)-` (subfolders, Watchtower worktrees under `F/.claude/worktrees/`), plus the same rule for every other worktree root of `F`: git's live list (`git worktree list --porcelain`, bounded by a 5 s timeout) merged with every root that a session of the workbench recorded in `terminal_session_worktrees` (`db.WorkbenchSessionWorktrees`), so a worktree removed by cleanup still has its history read. Symlinks are skipped (`Lstat`), including a symlinked `<session-uuid>/subagents` directory.

A session's home is the `cwd` of its first record that has one. It belongs to the workbench whose folder (or worktree root) contains the home, compared after `EvalSymlinks`; nested folders: the longest wins. A later `cd` does not move the session. When `terminal_sessions.claude_session_id` equals the session uuid the row records `terminal_session_id`.

Fields read per record: `message.id`, `requestId`, `message.usage` (incl. `cache_creation.ephemeral_*`, `speed`, `service_tier`), model, `cwd`, uuids, `attributionSkill`, `tool_use`/`tool_result` pairs, `toolUseResult` (interrupted, `structuredPatch` line counts), `cost-state.totalCostUSD`, compaction and API-error markers, `pr-link`. Overlong lines are skipped and counted; unknown record types are counted (`unknown_records`); a record of a read type (`assistant`, `user`, `system`, `pr-link`, `cost-state`) without a `sessionId` is counted as `<no-session>` and stores nothing; `<synthetic>` records carry no usage. Slash skills are recognized against the session's `skill_listing` names (the union of every listing); an incremental read collects the listings that sit before its offset only when a slash command of an unknown name needs them (at most once per read; a plain incremental scan never rereads the prefix, #571).

## Tables and the view

Migration `00116_agent_analytics.sql`:

- `projects.agent_analytics` (0/1) — the per-workbench switch.
- `agent_log_files` — per transcript: size, mtime, `read_offset` (end of the last complete line), `parser_version`, `missing_at`.
- `agent_log_sessions` — per session: `project_id` (SET NULL on delete), `folder_path`, `home_cwd`, `terminal_session_id`, `source_path`, branch, last model, start/end, `reported_cost_usd`.
- `agent_log_events` — one typed stream per session (`api_call`, `owner_turn`, `tool`, `skill`, `compaction`, `api_error`, `pr_link`) with a unique `key`, record uuid/parent/prompt ids for the timeline DAG, tool name/target/outcome/error class/duration, skill and trigger, the token buckets, cost fields, and `src_path` + `src_offset` pointing back into the JSONL (no text copy).
- `agent_log_session_totals` — a view summing the events; nothing is kept in sync by hand.

Mirrored into `schema.sql`, `TestAllTablesExist`, the golden snapshot and the generated Swift test schema.

## Dedupe and ownership rules

- `api_call` key `<message.id>:<requestId>` (`<message.id>:<session-uuid>` without a request id); the later record wins for tokens because streaming repeats the call with a growing `output_tokens`. `tool:<tool_use_id>`, `skill:<record uuid>:<n>`, `<kind>:<record uuid>` for the rest; a record without a uuid uses `<src path>:<byte offset>` in place of the uuid, so such records never share a row. Re-reading any file adds no row.
- A replayed record (resume, fork) belongs to the session with the earliest `started_at` (tie: smaller uuid); a later scan that finds an earlier owner moves the row, so scan order never matters.
- A subagent `api_call` whose `message.id` exists in the parent with another `requestId` is a replay and is skipped.
- Tool outcomes: `ok`, `error` (`exit_code`, `not_found`, `timeout`, `other`), `denied`, `interrupted`; an unpaired `tool_use` stays `pending` until a later scan pairs it.
- One file that fails to read or store is counted in `failed_files`, keeps the offset of its last committed slice (its old offset when the first slice failed) and is retried from there next scan; the other files are still read. A scan fails only for setup errors.
- Incremental reads: skip when size and mtime match; read from `read_offset`; reparse from 0 on shrink or an older `parser_version`; parse each slice before its write transaction. A read is stored in slices of at most 1000 events plus tool results (`agentlog.batchRows`), each in its own short transaction with its own offset compare-and-set, so the session hooks' 0.5–1 s lock budgets never wait behind a whole transcript or a reparse (#571). The scan budget is checked between slices; a stop mid-file keeps the committed slices, records `size` = the offset and an empty `mtime` (so the file never reads as unchanged) and resumes there next scan, meanwhile the analytics show that session partly. Streaming repeats and tool results across a slice boundary fold and pair in the database exactly as across two scans. The skill listings before the read's start stay available to every slice of that read until a slash command loads them; a slice whose records carry no timestamp never blanks a session's stored `started_at`. Vanished files get `missing_at`, rows stay.

## Cost

`internal/agentlog/pricing.go` holds a price table keyed by exact model id with explicit aliases, never a prefix match. Cache write 5m = 1.25x input, 1h = 2x input; the cache-read price is per model; a long-input tier where the model has one; a fast-speed multiplier per model. A model, tier or speed (anything but `""`, `standard`, `fast`) the table does not know costs 0 with `cost_estimated = 1`. Rows store `cost_usd`, `price_version` and `cost_estimated`. Any table change bumps `PriceVersion`; the next scan reprices older rows from stored tokens in transactions of 1000 rows (no reparse, no transcript needed). `reported_cost_usd` (Claude Code's own `cost-state` total) is kept per session to cross-check our sum; `agents stats` prints both. The Desktop reads `cost_usd` directly, so there is no Swift price table.

## Running it

- `watchtower agents enable --workbench N` sets the column and scans synchronously (`--json`: one summary object, the same shape as `agents scan --json`).
- `watchtower agents disable --workbench N` clears it; nothing is deleted.
- `watchtower agents scan --workbench N [--json]` — the incremental scan, then reprice. `--json` reports `unknown_records` (the `agentlog.Result` counter of unknown record types, plus `<invalid>` and `<no-session>`), so format drift is visible, and `failed_files` (files whose read or store failed this scan; the daemon logs the first error).
- `watchtower agents stats --workbench N --json` — totals and per-session figures with pinned keys (exactly `workbench_id`, `enabled`, `sessions`, `tokens`, `cost_usd`, `cost_estimated_calls`, `reported_cost_usd`, `owner_turns`, `tools`, `outcomes`, `skills`, `per_session`; pinned by `TestAgentsStatsJSON_PinnedKeys`).
- Daemon phase `phaseAgentAnalytics`: inert unless some workbench has the column set (the `phaseExternalSync` precedent); each cycle runs the incremental scan for every enabled workbench under a 30 s budget and resumes where it stopped. A budget stop never marks unread files missing.

## v1 limits (ingest core)

- Claude Code only; Codex (`~/.codex/sessions`, `.zst`, `token_count` deltas, subtracting replayed parent usage in fork/subagent rollouts) is the next step.
- `~/.claude` only: no `CLAUDE_CONFIG_DIR`, no multiple config dirs.
- No hooks (the Stop hook does not fire on an interrupt, so a sweep is needed anyway). The Desktop toggle and views are #298 (below).
- Analytics survive a workbench delete (below).
- The JSONL format is undocumented; the parser degrades by skipping and counting.

## Parser v2 (#298, `internal/agentlog`, `ParserVersion` 2, migration 00125, the Go migration `internal/db/migration_00125.go`)

The bump makes the next scan reparse every present file from 0 (idempotent keys, no duplicates). Migration 00125 adds `agent_log_events.spawned_agent_id` and `background` and rebuilds `agent_log_session_totals` so that `owner_turns` counts only `owner_turn` rows whose `trigger` is not `notification` or `hook` (a v1 row with `trigger = ''` still counts as owner).

Migration 00125 is a Go migration (#667, ask #361) so it tolerates the two columns already existing: a branch build applied them as its own version 124, leaving files that record 124 with the columns present and without main's `review_checks`, and the plain `ALTER`s failed every open with "duplicate column spawned_agent_id". Each column is added only when `pragma_table_info` lacks it (same DDL, same final schema), and 00124 is now `CREATE TABLE IF NOT EXISTS`, so the schema-drift repair on open replays the missing `review_checks`.

- **Shell verb** (`shellTarget`): the first real command of the line. It splits on `&&`, `||`, `;` and newline, cuts a pipeline at the first `|`, and skips `cd`, `pushd`, `popd`, `export`, `set`, `source`, `.`, leading env assignments and the `env`/`time`/`nice`/`timeout <n>` wrappers. Shape unchanged (program, plus the first argument for `git`, `gh`, `go`, `make`, `npm`, `swift`); `bash`/`sh`/`zsh` with a script argument store `bash <script base name>` (`bash dev-health.sh`), never a path or other arguments. A program name that fails the safe-name check stores nothing.
- **Owner turn `trigger`** (`turnTrigger`, leading whitespace ignored): `notification` when the text starts with `<task-notification>` or `<agent-message`; `hook` when it starts with `<system-reminder>` or `Stop hook feedback:`; otherwise `owner`. Reusing `trigger` avoided widening the `kind` CHECK.
- **Agent/Task calls**: `target` = `subagent_type` (`general-purpose` when absent or not a safe name); `background` from `run_in_background`; `spawned_agent_id` from the tool result's `agentId`, linking to the subagent's `agent_id`. A synchronous result is authoritative: it resets `background` to 0.
- **Workbench MCP targets**: calls of `update_target`, `add_comment`, `ask_owner`, `get_target`, `list_comments`, `finish_session` store `target = #<id>` from `target_id`; `create_targets` stores the first `parent_id` of its items. The server name is read with a hyphen or an underscore (Claude / Codex spelling). This is the conversation to board-target link the task view uses; only the id is read from the input.
- **Reparse refresh** (`upsertAgentLogEvent`): on conflict a non-empty `target` and `trigger` replace the stored ones and `background` takes the larger value, so a v1 to v2 reparse upgrades existing rows instead of keeping `cd`.

## The time model (`internal/agentreport`, pure; the caller loads rows)

Go owns every rule and hands JSON to the Desktop; there is no Swift twin.

- **Walk.** The main agent's events (`agent_id = ''`) of a session in `(ts, src_path, src_offset)` order. Each gap between two consecutive events belongs to exactly one category, so the categories sum to the wall time (first to last main event): `model`, `tool` (by class), `background`, `owner`, `away`. `active = wall - away`.
- **Tool classes** (`ToolClass`): `build_test` (`go test`/`go build`/`swift build`/`swift test`/`npm test`/`npm run`/`xcodebuild`, any `make`), `git` (`git`, `gh`), `read_search` (Read/Grep/Glob, `cat`/`ls`/`grep`/`rg`/`find`/`sed`/`head`/`tail`), `edit` (Edit/Write/MultiEdit/NotebookEdit), `mcp` (`mcp__*`), `subagents_fg` (Agent/Task with `background = 0`), `other`. A background Agent launch is `other` (its duration is the launch only). While several tool calls overlap, the gap goes to the earliest-started open one, so no stretch is counted twice.
- **Turn end and waits.** A turn ends on an `api_call` or an `api_error`; the wait runs, across see-through kinds (`compaction`, `pr_link`, `skill`), to the next `owner_turn` whose trigger is not `hook` (a hook record answers at once, so the gap before it is `model`). A wait is cut at the moments background spans open and close: the covered part is `background`; the uncovered part is `background` too when a `notification` turn closes the wait (the agent was working, with or without a stored span), and otherwise — an `owner` turn, or a v1 row's `''` — `owner` for the first 30 min of that wait (`AwayAfter`) and `away` after. So "waiting for you" never contains time before a notification, even if the owner writes before the notification arrives. A tool still pending when the next main event is an `owner_turn` does not swallow the wait: the gap is a wait, since the run time is unknown and inflating tool time is the worse error.
- **Background spans** are a subagent's first to last `ts`, with `background` and type taken from the Agent/Task call that spawned it (none found: foreground).
- **Subagents** (`SessionSubagents`): `count`, `foreground`, `background`, `peak` (most spans open at once), `busy_ms` (sum of spans), `union_ms` (union), `avg_parallel` (busy / union), `blocked_ms` (main agent inside foreground Agent calls) and `serial` (foreground subagents whose span overlaps no other). Subagents also produce one lane each for the timeline; no waits inside a subagent, its untooled time is model.
- **Old-format sessions**: any source file (the session's own or one its events point to) with `parser_version` below 2, missing or present; a present file stops flagging the session once its next scan reparses it at v2. They keep tokens and cost in the totals but are left out of the time model, subagents, commands and hints and carry `old_format` (`old_format_sessions` counts them).

## Tasks (board targets)

`Tasks` reads each target's `target_status_history`. Calendar time runs from the first `in_progress` to the last close (`done` and `dismissed` both close; an open target counts to now) and is split into `in_progress`, `in_review`, `blocked`, `todo`. Sessions are the ones that called a workbench tool naming the target (`#<id>`) or a sub-target. Agent time and cost are the session time inside the target's `in_progress`/`in_review` windows; with no window, or when the session's calls on the target lie outside every window, the fallback is the span from that session's first to last call naming it (a single call is a zero-length span). When one session has several targets open in the same window the stretch is split equally and the row is `shared` (a group is shared if any leaf is). Only leaves accumulate; a group sums its leaves, and a call naming a group only adds the session to its list. Cost counts the `api_call`s of every lane (subagents included), time uses the main lane. Time per task is a `TimeSplit` (`agent_ms` = its active time).

## Cost, models, commands

Cost is `cost_usd` as stored; `cost_estimated_calls` counts calls with `cost_estimated = 1`. `Models` sums by model, main vs subagent cost, tokens and cache read share (cache read / all input). `Commands` aggregates tool calls by verb (shell verb for Bash, else the tool name) with class, runs, errors, total and average time (pending calls are runs with no time); old-format sessions are excluded because their stored Bash verbs are v1 data (`cd`).

## Hints (rule-based, no LLM; thresholds are named constants at the top of `hints.go`)

Every hint has an id, a finding, evidence items (`session` uuid, `target` `#<id>`, or `command` verb) and an estimate in ms or USD; the list is ranked by estimate, time first, and a hint without an estimate is dropped.

| Id | Fires when | Estimate |
|---|---|---|
| H1 | one build & test verb ran 3+ times (`RepeatRuns`) inside one leaf target's `in_progress`/`in_review` window, or in one session when outside every window, totalling over 5 min (`RepeatMin`) | time of the runs after the first |
| H2 | read & search and `git status`/`log`/`diff` calls have a median over 5 s (`SlowCheapMedian`): likely permission prompts, suggests allow rules | (median - 1 s) x calls |
| H3 | a session has 3+ foreground subagents (`SerialMinFG`) and average parallelism under 1.3 (`SerialMaxParallel`) | foreground subagent time minus the longest run (an upper bound) |
| H4 | waiting for you is over 30 % (`OwnerShareMax`) of a session's or task's active time; one combined hint | the sessions' waiting time (largest task wait if only tasks fire) |
| H5 | one verb fails 3+ times in a row (`FailLoop`) in one agent lane; a success of that verb breaks the streak, other verbs do not | time of the failed runs |
| H6 | cache read share under 50 % with over $5 spent, or 2+ compactions | the session's cost |
| H7 | subagents on the top-priced models (all tied at the top output price) cost over 30 % of the period's spend | the same tokens re-priced at the next lower tier, standard speed (an estimate) |

## `watchtower agents report`

`watchtower agents report --workbench N [--days D (default 7, 0 = all) | --since YYYY-MM-DD (UTC)] [--session <uuid>] [--json]`; `--since` and `--days` are mutually exclusive. It reads only the database. Pinned keys (`TestAgentsReportJSON_PinnedKeys`): overview `commands`, `enabled`, `hints`, `models`, `old_format_sessions`, `sessions`, `since`, `subagents`, `tasks`, `time`, `totals`, `until`, `workbench_id`; `totals` = `active_ms`, `away_ms`, `cost_estimated_calls`, `cost_usd`, `sessions`, `tokens`; a session row = `active_ms`, `avg_parallel`, `branch`, `cost_usd`, `ended_at`, `model`, `old_format`, `prs`, `session_uuid`, `started_at`; the `--session` drill-down = `commands`, `hints`, `lanes`, `session`, `subagents`, `time`; `lanes` starts with the main agent (`agent_id` `""`) and then one lane per subagent, and is empty for an old-format session. Events are read in `(session_uuid, ts, src_path, src_offset, key)` order. An empty or disabled workbench returns empty arrays, never `null`; an unknown session fails with "not found". Budget: `BuildOverview` over 30 days of this repo's history (a 150k-event fixture, sized well above a heavy month of one folder's history) answers in under 1 s, asserted by `TestBuildOverview_Performance` with no env gate and no persisted aggregates; the assertion is skipped under `-short`, the race detector (`raceEnabled`) and coverage instrumentation (`testing.CoverMode() != ""`, as in CI's `make test-cover`), so plain `go test` asserts it.

## The Analytics pane (Desktop)

`WorkspacePane.analytics` next to Board and Files, project-wide like Board (`AgentAnalyticsPaneView` and siblings in `Views/Workbench/Analytics/`). `AgentAnalyticsCenter` (on `AppState`, the `SessionReportCenter` run discipline) runs the overview at once on show and on a period change (7 days / 30 days / All) and then every 60 s while the Workbench tab is on screen; one run per key plus one queued rerun, a failed run keeps the last good value marked stale. A session detail loads on open and is not polled.

- **Off:** an empty state with **Turn On** (`turnOn` runs `agents enable`, which loads the history synchronously and can take tens of seconds, then reloads the overview).
- **Overview:** tiles (active, away, cost, sessions), the subagent line, the time bar with the tool-class sub-line and the note "Tool time includes permission prompts.", hints, tasks (a click selects the target on the board; `shared` rows are labelled), sessions, models. "Older sessions — time not analysed: N" when `old_format_sessions` > 0.
- **Period label rule:** the heading comes from the report's own `since`/`until`, never from the picker; when they differ from the picker (a rerun is in flight or failed) a loading note shows, so numbers never sit under a wrong period.
- **No summed savings:** the pane never shows a total across hints, because hints can cite the same time or money (H1/H5, H6/H7).
- **Session detail:** breakdown, subagent figures, hints and a timeline (Swift Charts): one lane for the main agent and one per subagent, segments coloured by category ("You" is brown, apart from the orange of the pane's error lines), hover shows category, tool class and verb, duration.
- **Session report line:** the workbench session report shows "Agent time 27m · $12.50 · Analytics" for the terminal session's current `claude` conversation (from the loaded overview; hidden when there is no row or the row is old-format), linking to the session's analytics.
- Swift decodes the Go structs (`WatchtowerCore/Models/AgentReport.swift`); no rule is reimplemented in Swift. The decoding fixtures (`Tests/Core/Fixtures/agent-report-*.json`) are written by the Go builders: `TestDesktopReportFixtures` (`internal/agentreport`) seeds a placeholder database, runs `BuildOverview` and `BuildSession` at a fixed `now` and compares the JSON; `go test ./internal/agentreport -run TestDesktopReportFixtures -update` rewrites them.
- The pane's appear/disappear/period hooks sit on a stable `ZStack`, so moving between the overview and a session detail neither hides the center nor reruns the overview.

## v1 limits (#298)

- Tool time includes the time the owner takes to answer a permission prompt; the transcript does not separate it. The pane says so and H2 flags where it likely matters; the exact split needs hooks (#300).
- Claude Code only; Codex rows are not analysed yet (the views must not break when they arrive). `~/.claude` only.
- "Waiting for you" is capped at 30 min per wait; everything past it is `away` and outside active time. Parallelism is per session only: several sessions in one folder and machine load are not measured.

## Contracts

AGENTLOG-01..07 in `docs/inventory/agent-analytics.md`: no transcript text; each API call counts once; metrics outlive their source; only the workbench's transcripts are read; read-only on the agent's files; a session's time categories add up to its wall time; every hint cites evidence.

- **PROJ-02 exception (ask #153).** A workbench delete sets `project_id` and `terminal_session_id` to NULL on analytics rows; they stay with their `folder_path`, and a workbench later created on the same folder adopts them on its first scan. `TestProj02_DeleteProjectLeavesNoRows` asserts it.
- **FEAT-03 exception (ask #153).** Enabling loads the folder's history at once; the feature is not a registry entry (it is a per-workbench column), makes no AI calls and reads only local files. `phaseAgentAnalytics` joins FEAT-01's phase list gated by that column (`TestPhaseAgentAnalytics_InertWithoutEnabledWorkbench`).
