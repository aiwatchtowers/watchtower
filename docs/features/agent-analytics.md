# Agent analytics — ingest core (2026-10-15)

Board #296 (initiative), #297 (this sub-project). Spec: `docs/superpowers/specs/2026-10-15-agent-analytics-core-design.md`; plan: `docs/superpowers/plans/2026-10-15-agent-analytics-core.md`. Contracts: `docs/inventory/agent-analytics.md`.

## Purpose and the #296 roadmap

Turn analytics on for a workbench and see the history of every agent session run in its folder: tokens, cost, tools, skills, errors, denials, interruptions. #297 builds only the ingest core: it reads the agent's own transcripts, writes normalized rows into the shared SQLite and keeps them current.

| # | Sub-project | Order |
|---|---|---|
| #297 | Ingest core, Claude Code first (Codex is its follow-up step) | 1 |
| #298 | History analytics: dashboard, session timeline, commit/PR linking | 2 |
| #299 | Skill lab: with/without-skill evals, trigger precision/recall | 3 |
| #300 | Debug mode: OTel, verbose capture, LLM judge | 4 |

## Data source

Claude Code writes `~/.claude/projects/<slug>/<session-uuid>.jsonl`; subagents write `<slug>/<session-uuid>/subagents/agent-*.jsonl`. The slug is the cwd with every non-alphanumeric character replaced by `-` (lossy, so only a prefilter). For a workbench folder `F` the candidate directories are those named `slug(F)` or starting with `slug(F)-` (subfolders, Watchtower worktrees under `F/.claude/worktrees/`), plus the same rule for every other worktree root of `F` (`git worktree list --porcelain` and `terminal_session_worktrees`). Symlinks are skipped (`Lstat`).

A session's home is the `cwd` of its first record that has one. It belongs to the workbench whose folder (or worktree root) contains the home, compared after `EvalSymlinks`; nested folders: the longest wins. A later `cd` does not move the session. When `terminal_sessions.claude_session_id` equals the session uuid the row records `terminal_session_id`.

Fields read per record: `message.id`, `requestId`, `message.usage` (incl. `cache_creation.ephemeral_*`, `speed`, `service_tier`), model, `cwd`, uuids, `attributionSkill`, `tool_use`/`tool_result` pairs, `toolUseResult` (interrupted, `structuredPatch` line counts), `cost-state.totalCostUSD`, compaction and API-error markers, `pr-link`. Overlong lines are skipped and counted; unknown record types are counted (`unknown_records`); `<synthetic>` records carry no usage.

## Tables and the view

Migration `00116_agent_analytics.sql`:

- `projects.agent_analytics` (0/1) — the per-workbench switch.
- `agent_log_files` — per transcript: size, mtime, `read_offset` (end of the last complete line), `parser_version`, `missing_at`.
- `agent_log_sessions` — per session: `project_id` (SET NULL on delete), `folder_path`, `home_cwd`, `terminal_session_id`, `source_path`, branch, last model, start/end, `reported_cost_usd`.
- `agent_log_events` — one typed stream per session (`api_call`, `owner_turn`, `tool`, `skill`, `compaction`, `api_error`, `pr_link`) with a unique `key`, record uuid/parent/prompt ids for the timeline DAG, tool name/target/outcome/error class/duration, skill and trigger, the token buckets, cost fields, and `src_path` + `src_offset` pointing back into the JSONL (no text copy).
- `agent_log_session_totals` — a view summing the events; nothing is kept in sync by hand.

Mirrored into `schema.sql`, `TestAllTablesExist`, the golden snapshot and the generated Swift test schema.

## Dedupe and ownership rules

- `api_call` key `<message.id>:<requestId>` (`<message.id>:<session-uuid>` without a request id); the later record wins for tokens because streaming repeats the call with a growing `output_tokens`. `tool:<tool_use_id>`, `skill:<record uuid>:<n>`, `<kind>:<record uuid>` for the rest. Re-reading any file adds no row.
- A replayed record (resume, fork) belongs to the session with the earliest `started_at` (tie: smaller uuid); a later scan that finds an earlier owner moves the row, so scan order never matters.
- A subagent `api_call` whose `message.id` exists in the parent with another `requestId` is a replay and is skipped.
- Tool outcomes: `ok`, `error` (`exit_code`, `not_found`, `timeout`, `other`), `denied`, `interrupted`; an unpaired `tool_use` stays `pending` until a later scan pairs it.
- Incremental reads: skip when size and mtime match; read from `read_offset`; reparse from 0 on shrink or an older `parser_version`; parse before the write transaction; advance the offset by compare-and-set. Vanished files get `missing_at`, rows stay.

## Cost

`internal/agentlog/pricing.go` holds a price table keyed by exact model id with explicit aliases, never a prefix match. Cache write 5m = 1.25x input, 1h = 2x input; the cache-read price is per model; a long-input tier where the model has one; a fast-speed multiplier per model. A model or tier the table does not know costs 0 with `cost_estimated = 1`. Rows store `cost_usd`, `price_version` and `cost_estimated`. Any table change bumps `PriceVersion`; the next scan reprices older rows with one `UPDATE` from stored tokens (no reparse, no transcript needed). `reported_cost_usd` (Claude Code's own `cost-state` total) is kept per session to cross-check our sum; `agents stats` prints both. The Desktop reads `cost_usd` directly, so there is no Swift price table.

## Running it

- `watchtower agents enable --workbench N` sets the column and scans synchronously (`--json`: a line per file batch, then a summary).
- `watchtower agents disable --workbench N` clears it; nothing is deleted.
- `watchtower agents scan --workbench N [--json]` — the incremental scan, then reprice. `--json` reports `unknown_records` (the `agentlog.Result` counter of unknown record types), so format drift is visible.
- `watchtower agents stats --workbench N --json` — totals and per-session figures with pinned keys (exactly `workbench_id`, `enabled`, `sessions`, `tokens`, `cost_usd`, `cost_estimated_calls`, `reported_cost_usd`, `owner_turns`, `tools`, `outcomes`, `skills`, `per_session`; pinned by `TestAgentsStatsJSON_PinnedKeys`).
- Daemon phase `phaseAgentAnalytics`: inert unless some workbench has the column set (the `phaseExternalSync` precedent); each cycle runs the incremental scan for every enabled workbench under a 30 s budget and resumes where it stopped. A budget stop never marks unread files missing.

## v1 limits

- Claude Code only; Codex (`~/.codex/sessions`, `.zst`, `token_count` deltas, subtracting replayed parent usage in fork/subagent rollouts) is the next step.
- `~/.claude` only: no `CLAUDE_CONFIG_DIR`, no multiple config dirs.
- No Desktop UI (toggle and views arrive in #298); no hooks (the Stop hook does not fire on an interrupt, so a sweep is needed anyway).
- Analytics survive a workbench delete (below).
- The JSONL format is undocumented; the parser degrades by skipping and counting.

## Contracts

AGENTLOG-01..05 in `docs/inventory/agent-analytics.md`: no transcript text; each API call counts once; metrics outlive their source; only the workbench's transcripts are read; read-only on the agent's files.

- **PROJ-02 exception (ask #153).** A workbench delete sets `project_id` and `terminal_session_id` to NULL on analytics rows; they stay with their `folder_path`, and a workbench later created on the same folder adopts them on its first scan. `TestProj02_DeleteProjectLeavesNoRows` asserts it.
- **FEAT-03 exception (ask #153).** Enabling loads the folder's history at once; the feature is not a registry entry (it is a per-workbench column), makes no AI calls and reads only local files. `phaseAgentAnalytics` joins FEAT-01's phase list gated by that column (`TestPhaseAgentAnalytics_InertWithoutEnabledWorkbench`).
