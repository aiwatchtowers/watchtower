# Agent analytics — ingest core (Claude Code transcripts → metrics)

**Date:** 2026-10-15
**Status:** design agreed (asks #151, #152, #153); spec under review
**Board:** #296 (initiative), #297 (this sub-project)

## Goal

Any Watchtower user turns analytics on for a workbench and at once sees the history
of every agent session run in that folder: tokens, cost, tools, skills, errors,
denials, interruptions. This sub-project builds only the **ingest core**: it reads the
agent's own session transcripts, turns them into a small set of normalized rows in
the shared SQLite, and keeps them current. Everything the owner looks at is built on
top of it by the later sub-projects.

### The initiative and where this fits

| # | Sub-project | Order |
|---|-------------|-------|
| #297 | **Ingest core** (this spec) — Claude Code first, Codex as its follow-up step | 1 |
| #298 | History analytics — workbench dashboard, session timeline, commit/PR linking | 2 |
| #299 | Skill lab — with/without-skill evals, Skill Lift, trigger precision/recall | 3 |
| #300 | Debug mode — OTel, verbose capture, LLM judge over a session | 4 |

### Decisions taken with the owner

| Ask | Decision |
|-----|----------|
| #151 | Audience: any Watchtower user, not only the owner. |
| #151 | Data from transcripts (and hooks where they add something); evals are part of the initiative (#299). |
| #151 | Two modes: history (passive) and debug (spends tokens). "I turn it on in a workbench and see everything." |
| #152 | Order: ingest core, history analytics, skill lab, debug mode (#297 → #298 → #299 → #300). |
| #152 | Store metrics plus a reference into the source JSONL — never a copy of the text. |
| #152 | Scope: every session of the folder and its worktrees, not only Watchtower-launched ones. |
| #152 | Debug mode: a workbench switch plus a per-session override (built in #300). |
| #153 | Backfilling history on enable is an approved exception to FEAT-03 (not a registry feature, no AI calls). |
| #153 | Codex is the next step of #297, after the Claude part ships. |
| #153 | Metrics are kept forever. |
| #153 | Deleting a workbench keeps its analytics rows (PROJ-02 gains an explicit exception). |
| — | Owner rule for this design: no extra complexity; machinery only where skipping it gives silently wrong numbers. |

### Research this design rests on

Three studies of open-source projects (ccusage, token-dashboard,
dashboard-for-claude-code, sniffly, claude-code-log, agit, Entire, agentplay,
git-memento, skill-creator, `claude plugin eval`, the official `session-report`
plugin, Claude Code OTel) and an adversarial design review. What they changed here:

- Usage is deduplicated at the **API-call grain** `(message.id, requestId)` across all
  files, keeping the last record — streamed chunks repeat usage (summing every line
  overcounts output 2–3×), and resumed/forked sessions and subagent files replay
  parent records.
- A session's project comes from the record's **`cwd`**, not the directory name (the
  name is a lossy encoding); the name is only a cheap prefilter.
- Incremental reads keep **an offset to the last complete line**, reparse from 0 when
  a file shrinks, and rely on idempotent keys rather than wipe-and-rescan — Claude
  Code deletes transcripts after ~30 days (`cleanupPeriodDays`), so a rescan could
  lose history for good.
- One typed **event stream** per session (agit, agentplay) serves the later timeline
  better than per-kind tables.
- Store no text (agentplay); shell commands keep only their verb.
- The whole local store measured 595 MB / 646 Claude files: a full backfill parses in
  seconds, so it runs synchronously on enable rather than as a budgeted daemon job.

## Scope

**In (v1 = Claude Code):** discovery, parser, the three tables, cost at ingest, the
`watchtower agents` CLI, a daemon phase for incremental updates, contracts and the
feature note.

**Follow-up step of #297 (Codex):** the same pipeline for `~/.codex/sessions` and
`archived_sessions`, incl. `.zst`, `token_count` deltas, and subtracting the parent's
replayed usage in fork/subagent rollouts (28 of 60 local rollouts are subagent ones —
without this the numbers silently double). It gets its own short plan once v1 ships.

**Out:** any Desktop UI (the toggle and every view come in #298); commit/PR linking
(#298 — the core only records what it needs, see Events); hooks (none in v1); evals
(#299); OTel and the judge (#300); `CLAUDE_CONFIG_DIR` and multiple config dirs (v1
reads `~/.claude`, the same dual-path rule as `defaultTerminalClaudeDir`).

## Discovery — which transcripts belong to a workbench

1. **Candidate directories.** Claude Code stores a session at
   `~/.claude/projects/<slug>/<session-uuid>.jsonl`, where `<slug>` is the cwd with
   every non-alphanumeric character replaced by `-`; subagent transcripts live at
   `<slug>/<session-uuid>/subagents/agent-*.jsonl`. For a workbench with folder `F`
   the candidates are the directories whose name equals `slug(F)` or starts with
   `slug(F) + "-"` (this covers subfolders and Watchtower's own worktrees under
   `F/.claude/worktrees/…`, even removed ones), plus the same rule for every worktree
   root of `F` that lives elsewhere (`git worktree list --porcelain` run in `F`, and
   the roots in `terminal_session_worktrees` for the workbench's sessions). No other
   project's transcripts are opened.
2. **Confirmation by home cwd.** A session's **home** is the `cwd` of its first record
   that has one. The session belongs to workbench `W` when the home lies inside `W`'s
   folder or one of its worktree roots; when two workbench folders match (nested
   folders), the longest folder wins. Paths are compared after `filepath.EvalSymlinks`
   when they exist. A session that later `cd`s elsewhere stays with its home (23 of 43
   sampled sessions change cwd mid-way).
3. **Link to Watchtower's own sessions.** When `terminal_sessions.claude_session_id`
   equals the session uuid, the session row records that `terminal_session_id`.
4. **Symlinks.** Directory entries are `Lstat`ed; symlinked files and directories are
   skipped (the containment rule `FindTranscript` already follows).

## Parsing — what each record becomes

The parser reads one line at a time with the existing size cap (longer lines are
skipped and counted), tolerates unknown record types (counted per type and reported
by `agents scan --json`), guards every field, and never fails a file because of one
bad line. Records with model `<synthetic>` carry no usage.

Each kept record becomes zero or more **events** of one session. The **event kinds**:

| Kind | From | Main fields |
|------|------|-------------|
| `api_call` | assistant record with `message.usage` | model, the token buckets, `speed`, `service_tier`, `skill` (Claude Code's `attributionSkill`), cost |
| `owner_turn` | user record that is a real owner prompt (not a tool result, not meta) | — (no text) |
| `tool` | `tool_use` block paired with its `tool_result` by `tool_use_id` | name, target, outcome, error class, duration, `skill`, lines added/removed |
| `skill` | a `Skill` tool call, a slash-invoked skill, or a `Read` of a `SKILL.md` | skill name, trigger `proactive` / `slash` / `read` |
| `compaction` | compact boundary / `isCompactSummary` | — |
| `api_error` | `isApiErrorMessage` | — |
| `pr_link` | a `pr-link` record, when present | target = the PR URL |

- **Tool outcome:** `ok`; `error` (`is_error` result) with a small class set
  (`exit_code`, `not_found`, `timeout`, `other`); `denied` (permission denial —
  `toolDenialKind`, a deny `permissionDecision`, or the owner's rejection text);
  `interrupted` (`toolUseResult.interrupted` or the "Request interrupted by user"
  marker). A `tool_use` with no result yet stays `pending` until a later scan pairs it.
- **Tool target, without content:** a file path relative to the session's workbench
  folder (`<outside>` when it is not inside it); for a shell command, the program
  name, plus its first argument for `git`, `gh`, `go`, `make`, `npm`, `swift`
  (`git commit`, `gh pr`) — enough for #298 to find commits and PRs, never arguments
  beyond that. Other tools: no target.
- **Lines added/removed** come from `toolUseResult.structuredPatch` of edit tools.
- **Subagents.** Records in a subagent file belong to the parent session (`agent_id`
  set, `is_sidechain` true). An `api_call` in a subagent file whose `message.id`
  already exists in the parent with another `requestId` is a replay and is skipped.
- **Claude Code's own total.** The last `cost-state` record's `totalCostUSD` is kept on
  the session as `reported_cost_usd` to cross-check our sum (`agents stats` prints
  both).

### Natural keys and dedupe

Every event has a unique `key`, so re-reading any file never adds a row:

- `api_call`: `<message.id>:<requestId>` (`<message.id>:<session-uuid>` when
  `requestId` is missing). On conflict the later record wins for the token columns —
  streaming repeats the same call with growing `output_tokens`.
- `tool`: `tool:<tool_use_id>`; `skill`: `skill:<record uuid>:<n>`; other kinds:
  `<kind>:<record uuid>`.

**Ownership of a replayed record.** Resumed and forked sessions copy the parent's
records (same keys) into a new file with a new `sessionId`. The event belongs to the
session whose `started_at` is earliest (tie: the smaller uuid); a later scan that finds
an earlier owner moves the row. This keeps the result independent of scan order.

## Cost — computed at ingest

- Each `api_call` stores its tokens: `input`, `output`, `cache_read`,
  `cache_write_5m`, `cache_write_1h` (from `cache_creation.ephemeral_*`; a missing
  breakdown counts as 5m), plus `speed` and `service_tier`.
- `internal/agentlog/pricing.go` holds a versioned price table keyed by **exact model
  id** with explicit aliases — never a prefix match, so a future model is not priced
  silently. Rules: cache write 5m = 1.25× input, 1h = 2× input; the cache-read price
  is set per model (it is not always 0.1× input — Fable 5.1 reads at $0.25 against $10
  input, Opus 5.5 at $0.20 against $4); a long-input tier where the model has one
  (Haiku 5.5 above 100K input); a fast-speed multiplier per model, unknown → estimated.
- The row stores `cost_usd`, `price_version` and `cost_estimated` (1 for a model or
  tier the table does not know; its cost is then 0 and the flag says so).
- A price-table change bumps `price_version`; the next scan reprices old rows with one
  `UPDATE` from their stored tokens — no reparse, no transcript needed.
- The Desktop reads `cost_usd` directly (GRDB) — no Swift price table, no dual path.

## Storage — migration `00116_agent_analytics.sql`

```sql
ALTER TABLE projects ADD COLUMN agent_analytics INTEGER NOT NULL DEFAULT 0
  CHECK (agent_analytics IN (0, 1));

CREATE TABLE agent_log_files (
  path           TEXT PRIMARY KEY,           -- absolute transcript path
  agent          TEXT NOT NULL CHECK (agent IN ('claude')),   -- 'codex' joins in the Codex step
  size           INTEGER NOT NULL DEFAULT 0,
  mtime          TEXT NOT NULL DEFAULT '',
  read_offset    INTEGER NOT NULL DEFAULT 0, -- end of the last complete line read
  parser_version INTEGER NOT NULL DEFAULT 0,
  missing_at     TEXT,                       -- the file is gone; its rows stay
  scanned_at     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE agent_log_sessions (
  session_uuid        TEXT PRIMARY KEY,
  agent               TEXT NOT NULL CHECK (agent IN ('claude')),
  project_id          INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  folder_path         TEXT NOT NULL,         -- the workbench folder it was matched to
  home_cwd            TEXT NOT NULL,
  terminal_session_id INTEGER REFERENCES terminal_sessions(id) ON DELETE SET NULL,
  source_path         TEXT NOT NULL,         -- the main transcript file
  git_branch          TEXT NOT NULL DEFAULT '',
  model               TEXT NOT NULL DEFAULT '', -- the last model seen
  started_at          TEXT NOT NULL,
  ended_at            TEXT NOT NULL,
  reported_cost_usd   REAL                   -- Claude Code's own total, when present
);
CREATE INDEX idx_agent_log_sessions_project ON agent_log_sessions(project_id, started_at);

CREATE TABLE agent_log_events (
  id             INTEGER PRIMARY KEY,
  session_uuid   TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  key            TEXT NOT NULL UNIQUE,
  kind           TEXT NOT NULL CHECK (kind IN
                   ('api_call','owner_turn','tool','skill','compaction','api_error','pr_link')),
  ts             TEXT NOT NULL,
  uuid           TEXT NOT NULL DEFAULT '',   -- record uuid / parentUuid / promptId:
  parent_uuid    TEXT NOT NULL DEFAULT '',   --   the DAG the #298 timeline orders by
  prompt_id      TEXT NOT NULL DEFAULT '',
  agent_id       TEXT NOT NULL DEFAULT '',   -- subagent id; '' = main agent
  is_sidechain   INTEGER NOT NULL DEFAULT 0,
  name           TEXT NOT NULL DEFAULT '',   -- tool name / skill name / model
  target         TEXT NOT NULL DEFAULT '',
  trigger        TEXT NOT NULL DEFAULT '',   -- skill: proactive | slash | read
  outcome        TEXT NOT NULL DEFAULT '' CHECK (outcome IN
                   ('','ok','error','denied','interrupted','pending')),
  error_class    TEXT NOT NULL DEFAULT '',
  duration_ms    INTEGER,
  skill          TEXT NOT NULL DEFAULT '',   -- attributionSkill
  input_tokens   INTEGER NOT NULL DEFAULT 0,
  output_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_write_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0,
  speed          TEXT NOT NULL DEFAULT '',
  service_tier   TEXT NOT NULL DEFAULT '',
  cost_usd       REAL NOT NULL DEFAULT 0,
  price_version  INTEGER NOT NULL DEFAULT 0,
  cost_estimated INTEGER NOT NULL DEFAULT 0,
  lines_added    INTEGER NOT NULL DEFAULT 0,
  lines_removed  INTEGER NOT NULL DEFAULT 0,
  src_path       TEXT NOT NULL,              -- where the record is: file + byte offset
  src_offset     INTEGER NOT NULL
);
CREATE INDEX idx_agent_log_events_session ON agent_log_events(session_uuid, ts);
CREATE INDEX idx_agent_log_events_kind ON agent_log_events(kind, name);
```

Session totals (tokens, cost, tool counts by outcome, skills) are **not stored**: a
view `agent_log_session_totals` sums them from the events, so there is nothing to keep
in sync. Mirrored into `schema.sql`, `TestAllTablesExist`, the golden snapshot and
the generated Swift test schema per the migration rules.

**Workbench delete (PROJ-02 exception, ask #153).** `project_id` is set NULL and
`terminal_session_id` too; the rows stay with their `folder_path`. A workbench later
created on the same folder adopts them on its first scan (`project_id` is re-set where
`folder_path` matches).

## Running it

- **`watchtower agents enable --workbench N`** sets `projects.agent_analytics = 1`
  and runs the scan below synchronously, printing progress (`--json`: one line per
  file batch, then a summary). Seconds even for hundreds of MB, so "turn it on and see
  it" holds without waiting for the daemon. FEAT-03 exception per ask #153; the
  feature is **not** a registry entry (`internal/features` needs a config key; this is
  a per-workbench column).
- **`watchtower agents disable --workbench N`** sets it to 0. Nothing is deleted
  (FEAT-02 spirit); the daemon stops updating it.
- **`watchtower agents scan --workbench N [--json]`** — the incremental scan: for each
  candidate file, skip it when size and mtime match the stored row; read from
  `read_offset` to the last complete line (from 0 when the file shrank or
  `parser_version` is older); parse **before** opening the write transaction
  (BEGIN IMMEDIATE holds the lock from its first statement); write the events with
  upserts on `key`; then advance `read_offset` with a compare-and-set
  (`UPDATE … WHERE path = ? AND read_offset = ?`) — if another writer moved it first, the
  transaction rolls back (idempotent keys make a double write harmless anyway).
  Files that vanished get `missing_at`, their rows stay. Then reprice rows with an
  older `price_version`.
- **`watchtower agents stats --workbench N --json`** — totals for the workbench and
  per session with pinned keys (`sessions`, `tokens`, `cost_usd`, `cost_estimated`,
  `reported_cost_usd`, `tools`, `outcomes`, `skills`, `unknown_records`). It is the
  CLI face of the core and the fixture for its tests; #298's Desktop reads the tables.
- **Daemon phase `phaseAgentAnalytics`** — inert unless some workbench has
  `agent_analytics = 1` (the `phaseExternalSync` precedent); each cycle runs the
  incremental scan for every enabled workbench under a 30 s budget, resuming next
  cycle where it stopped. No hooks in v1: the Stop hook does not fire on an
  interrupt anyway, so a sweep is needed regardless.

## Contracts (new inventory file `docs/inventory/agent-analytics.md`)

- **AGENTLOG-01 — No transcript text.** No owner prompt, agent reply, tool input or
  output, file content or command argument beyond the documented target is stored.
  Guard: a fixture full of sentinel strings, then a scan; no sentinel appears in any
  column.
- **AGENTLOG-02 — Each API call counts once.** Streaming duplicates, resumed and forked
  copies, and subagent replays never double tokens or cost, whatever the scan order.
  Guard: golden fixtures for each case, scanned in two orders.
- **AGENTLOG-03 — Metrics outlive their source.** A deleted transcript, a parser bump or
  a workbench delete never removes rows. Guard: scan, delete the file, bump the parser
  version, rescan; totals unchanged.
- **AGENTLOG-04 — Only the workbench's transcripts are read.** Directories outside the
  candidate rule are never opened. Guard: a fake `~/.claude/projects` with an
  unrelated project; the scan opens none of its files.
- **AGENTLOG-05 — Read-only on the agent's files.** The core never writes, moves or
  deletes anything under `~/.claude`.

Amended: **PROJ-02** (analytics rows survive a workbench delete with `project_id`
NULL; guard asserts it; owner approval ask #153); **FEAT-03** changelog (backfill on
workbench enable is outside the registry; ask #153); **FEAT-01** phase list notes
`phaseAgentAnalytics` as gated by the workbench column, not a config key.

## Testing

Synthetic JSONL fixtures only (public repo): `internal/agentlog/testdata/`. Golden
cases: streaming duplicates; resume and fork copies; a subagent file replaying parent
messages; compaction; a partial last line completed on the next scan; a shrunk file;
a deleted file; unknown record types; `<synthetic>` model; an unknown model (estimated
cost); a session that `cd`s out of the folder; nested workbench folders; a symlinked
directory; a pending tool result paired on a later scan; reprice after a price-table
bump. Package tests stay in `go test ./internal/agentlog`; the CLI gets pinned-key
tests; the migration runs through the usual schema goldens.

## Open risks

- The JSONL format is undocumented and changes; the parser degrades by skipping and
  counting, and `agents scan --json` surfaces `unknown_records` so drift is visible.
- Model prices change; the table lives in code and is updated with releases; unknown
  models are flagged, never guessed.
- `reported_cost_usd` and our sum may differ (Claude Code's own accounting rules);
  the difference is shown, not hidden.
