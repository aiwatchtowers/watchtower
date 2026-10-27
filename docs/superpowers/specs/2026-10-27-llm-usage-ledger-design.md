# LLM usage ledger — what Watchtower itself spends on AI (design)

**Date:** 2026-10-27 · **Board:** #1169 · **Status:** draft for owner review

## Intent

The owner wants to see, on the Usage screen, how much LLM Watchtower spends **for its own
needs** — syncing, digests, briefing, ideas, memory, media, automations — split by process, so
they can optimise how Watchtower collects information. Workbench sessions and chats are not
part of that number; they get one combined total on the same screen for comparison.

The numbers must be trustworthy. Today they are not.

## What is wrong today (audit, 2026-10-27, live install read-only, last 14 days)

1. **Input is almost always missing.** `pipeline_runs.input_tokens` stores the Claude CLI's
   `usage.input_tokens`, which is only the uncached part of the prompt (a briefing: 2 tokens
   against ~7 000 the API processed). Cache read and cache creation are folded into
   `total_api_tokens`; the `cache_read_tokens`/`cache_creation_tokens` columns stay 0
   (`internal/digest/generator.go` `cliUsageOf`).
2. **Cost is always $0.** The CLI's `total_cost_usd` is parsed and dropped (`CostUSD: 0`).
3. **Recording is opt-in.** A run is recorded only where code wraps it in
   `trackedPipelineRun`/`CreatePipelineRun`, and the wrapper sums whatever usage the pipeline
   chose to return. Catch-up, reviewai, spec review, targets AI, Jira AI fields, dictation,
   terminal titles, `ask` and media either write elsewhere or nowhere; usage is discarded
   (`_`) at several sites.
4. **Thousands of zero rows.** `digests`, `inbox`, `tracks`, `next_step`,
   `reaction-commands`, `knowledge-index`: ~1 270 runs each with 0 tokens — "no LLM call"
   cannot be told from "a call that was not recorded".
5. **Automations are invisible.** Their usage lives in `automation_runs` (and estimates
   length/4 when the provider reports nothing) and never reaches Usage. The largest single
   consumer on the live install was an owner automation (~1.07 M output tokens in 14 days),
   more than every recorded pipeline together.
6. **Streaming calls report nothing.** `ai.Client.Query`, `codex.Client.Query` and
   `ollama.Client.Query` drop the usage of the final event; the warm chat session's usage only
   goes to the Desktop over stdout.

## Goals

- G1. One row per LLM call made by any Watchtower Go process, recorded at the lowest shared
  layer, so a new feature cannot bypass it by forgetting to opt in.
- G2. Every row says **who** asked (a purpose such as `digest.channel`, `media.describe`,
  `automation.llm`) and **for whom** (surface: Watchtower itself, a chat, a workbench).
- G3. Full token split per call: fresh input, cache read, cache write, output; plus cost —
  the provider's reported cost when it gives one, else an estimate from the price table,
  marked as an estimate.
- G4. A Usage tab **Watchtower**: totals and a per-process table for a chosen period, plus a
  **Chats and workbenches** block with one total each.
- G5. Gaps are visible, never silent: a call without a purpose shows as **Untagged** with the
  command that made it; a call without provider usage is marked estimated and counted.

## Non-goals

- No change to `pipeline_runs` storage. Every screen that reads its token columns **stops
  showing tokens and cost**, so wrong numbers are not left on screen next to right ones:
  - the **Usage** run-history tab stays the run log (status, duration, items, errors); its
    token badges and summary numbers are removed and replaced by one line "Tokens and cost:
    see the Watchtower tab" with a button that switches to it;
  - the **Progress** tab (`ProgressDetailView`) drops its per-run Input / Input (+ cache) /
    Output rows and the per-step `in/out` token text, with the same one-line pointer under a
    run's details.
  - **Home → Numbers "AI spend"** (`HomeNumbersQueries` → `TokenUsageQueries.fetchUsage`,
    today's `pipeline_runs.cost_usd`, always $0 today) takes its number from the same
    `usage llm --since today --json` the tab uses — no second implementation in Swift. It shows
    `page_total` (Watchtower + your automations + chats; workbenches are not in it), labelled
    "AI spend today", with the tooltip "Watchtower, your automations and chats — workbenches
    are on Usage → Watchtower", the same "≈"/"≥" marks, and opens Usage → Watchtower. It
    includes spooled rows exactly like the tab, so the two never disagree. Refreshed when Home
    appears and every 5 minutes while it is visible.
  The changed screens are in the mockup and get `DesignShotCatalog` shots.
- No budgets, alerts or limits on top of the ledger (later, if wanted).
- No per-chat or per-workbench drill-down — one total line each is what was asked.
- No Desktop-side (Swift) LLM calls: the Desktop does not call a model directly, it runs the CLI.

## Anti-goals

- A number on the screen that silently undercounts. If something is not measured, the screen
  says so (estimated calls count, Untagged row, "workbench analytics off" note).
- An LLM call that fails or slows down because the ledger write failed: recording is
  best-effort and never changes the call's result.

## Design

### 1. Ledger table `llm_calls` (migration, `watchtower.db`)

One row per finished (or failed) model call:

| column | meaning |
|---|---|
| `id` | rowid |
| `call_id` | 16 random hex chars, UNIQUE — makes spool imports idempotent |
| `at` | RFC 3339 UTC finish time |
| `surface` | `watchtower` \| `chat` \| `workbench` |
| `purpose` | the ctx source tag (`digest.channel`, `automation.llm`, …), `''` = untagged |
| `process` | the process kind + command path: `daemon`, `cli:jira boards`, `mcp:workbench`, `ai session`, … |
| `provider` | `claude` \| `codex` \| `ollama` \| `http` (runtime B) |
| `model` | model id as the provider reported it, else the requested one |
| `input_tokens` | fresh (uncached) input |
| `cache_read_tokens` | prompt-cache reads |
| `cache_write_5m_tokens`, `cache_write_1h_tokens` | prompt-cache writes by TTL, as `agentlog.Cost` needs them. The Claude result's `usage.cache_creation.ephemeral_5m/1h_input_tokens` fill them; when only the total `cache_creation_input_tokens` is present it goes to `5m` (the CLI's default TTL) |
| `output_tokens` | output |
| `usage_estimated` | 1 when the provider reported no usage and the tokens are length/4 |
| `reported_cost_usd` | the provider's own cost (Claude CLI `total_cost_usd`), NULL when none |
| `est_cost_usd` | price-table estimate, NULL when the model has no price |
| `duration_ms` | wall time of the call |
| `ok` | 1 success, 0 error |
| `automation_id` | the automation run's automation, NULL otherwise |
| `automation_run_id` | the automation run, NULL otherwise (for the reconciliation check) |

Indexes on `at` and `(surface, at)`. Rows older than 90 days are deleted once a day by the
daemon (proposed retention; the screen's longest period is 30 days). Mirrored into `schema.sql`, `TestAllTablesExist`, golden + Swift test schema (CLAUDE.md
migration rules).

### 2. Recording point: `internal/llmusage`

A leaf package (no imports of digest/ai/codex) with:

- `Call` struct (the columns above minus `id`, `at`, `surface`, `process` which the sink fills).
- context helpers: `WithPurpose`/`PurposeFrom`, `WithSurface`/`SurfaceFrom`,
  `WithAutomation`/`AutomationFrom`. `digest.WithSource`/`SourceFromContext` become thin
  wrappers over `WithPurpose`/`PurposeFrom`, so the ~60 existing tagged call sites are tagged
  for the ledger without edits.
- `Record(ctx, Call)` — hands the row to the process's installed `Sink`.
- `SetSink(Sink)` — the daemon installs the DB sink; every other process writes through the
  spool below (plan simplification: one write path for the 100+ CLI entry points, no extra
  write-lock traffic from hooks and short commands). The DB sink writes one short `INSERT` (its own autocommit, never inside a
  caller's transaction; measured by lockmetrics like every write).
- **No call is lost.** Every process except the daemon appends its rows to the spool file
  `<workspace>/llm_calls.spool.jsonl` (0600; numbers, purpose, process and model only — no
  prompt or response text, FILES-01). The daemon writes its own rows straight to the table and
  imports the spool at the start of each cycle (rename to `.importing` under a sidecar flock,
  so a writer appending meanwhile is not lost; `call_id` UNIQUE + `INSERT OR IGNORE`, so a
  crash between insert and delete imports nothing twice). The daemon is the **only** writer
  of `llm_calls`.
- **When the spool cannot be written** (disk full, permissions), there is no later write in a
  short-lived process to carry a counter, so the fallback is immediate, in order:
  1. a direct `INSERT` into `llm_calls` of the workspace database (opened lazily by path;
     the only exception to "the daemon is the only writer", taken only on this failure);
  2. if that fails too, one line per lost call, `llmusage: call not recorded (<purpose>,
     <process>): <error class>`, appended to `<workspace>/watchtower.log` and written to
     stderr. A command run from a terminal or a hook therefore leaves the line in the log as
     well as on the terminal.
  The screen cannot count calls lost on both paths, and when even the log append fails (the
  disk is the usual cause of all three) the loss is only on stderr; the feature note lists
  this as the v1 limit.

`Record` is called from **each leaf implementation's usage funnel** — the place that already
has the provider's numbers:

| leaf | where |
|---|---|
| `digest.ClaudeGenerator` `Generate`/`GenerateWithImage` | after `cliUsageOf` (with cache split + `total_cost_usd`) |
| `codex.CodexGenerator.run` | after `parseJSONLOutput` |
| `ollama.Generator.Generate` | after the response's `usage` (estimated when absent) |
| `ai.Client.QuerySync` and `ai.Client.Query` | `Query` keeps the final result event's usage and records it at the end of the stream |
| `codex.Client.QuerySync`/`Query` | `Query` records from the turn's completion usage, estimated when absent |
| `ollama.Client.QuerySync`/`Query` | `Query` asks for `stream_options.include_usage` |
| `agentloop` `meteredChat` | per model call |
| `chat.ClaudeTranslator.result` (warm `ai session`) | from the `result` line's usage incl. cache fields |
| `ValidateModel` and other probes | recorded with purpose `probe` |

Wrappers (`PooledGenerator`, `timeoutGenerator`, `policyChecked*`) do not record — only leaves,
so nothing is counted twice.

**Guard test** (`TestLLMUsageLeaves`): parses the Go tree and lists every non-test type with a
`Generate(ctx, …)`/`QuerySync`/`Query` method matching the provider interfaces, or that execs
`claude`/`codex` or posts to a chat-completions URL; each must be either in the recording-leaf
list or the known-wrapper list. A new leaf that does not record fails the test.

### 3. Purpose and surface tagging

- **Purpose:** the existing `digest.WithSource` tags. Paths that call `ai.Provider` without a
  tag today (Jira fields/board analyzer, `ask`, spec review, reviewai's discarded usage, automation
  `agent()`) get one at the call site. A call with no purpose is stored with `purpose = ''`
  and shows as **Untagged** with its `process`.
- **Surface** defaults to `watchtower`. It is set once at the process/entry level:
  - `chat`: `ai session` (all surfaces), `ai query` (embedded and help chats).
  - `workbench`: `mcp --workbench` server tools, `workbench spec-review run`,
    `workbench review …` (reviewai), terminal-title generation, and any other `workbench …`
    command.
  - Automations stay `watchtower` with `automation_id` set, but the screen splits them by
    origin: **built-in** automations (Morning brief, Track my threads, Idea finder, Reactions)
    are Watchtower's own information work and sit in the main table; **the owner's own
    automations** (origin `owner`, incl. workbench-scoped ones) are a separate section "Your
    automations" with its own subtotal, one row per automation. The main total ("Watchtower
    collecting and processing") excludes them; the page total includes both.
- `ai test` (provider ping) gets purpose `probe`.

### 4. Cost

- `reported_cost_usd` = what the provider reported (Claude CLI). The Claude CLI reports an
  API-equivalent price even on a subscription; the screen labels the column "API-equivalent $".
- `est_cost_usd` = `agentlog.Cost(model, "", input, output, cacheRead, cw5m, cw1h)` (moved
  or re-exported to a shared place) at record time;
  the price table gets alias resolution for the short names Watchtower passes (`opus`,
  `sonnet`, `haiku`). Codex/Ollama models have no price → NULL, shown as "—".
- The screen shows reported cost when present, else the estimate prefixed with "≈".
- When any call in a total has no cost (no price for the model), that total reads
  "≥ $X" and the totals row says "N calls without a price (Codex/Ollama)"; such calls still
  count fully in the token columns.

### 5. CLI: `watchtower usage llm`

`watchtower usage llm [--since 1d|7d|30d] [--json]` aggregates in Go (single source of truth
for the screen and the terminal):

- `watchtower`: totals (calls, errors, input, cache read, cache write, output, cost,
  estimated-usage calls, cost-unknown calls) and `by_purpose` rows (purpose,
  display group, calls, tokens, cost, avg tokens per call, models) for Watchtower's own work
  incl. built-in automations.
- `own_automations`: totals + one row per owner automation (name, runs, calls, tokens,
  output, cost).
- `chats`: one totals object (surface `chat`).
- `workbenches`: one totals object = `sessions` (agent sessions from `agentlog.db` events in
  the period, workbenches with agent analytics on) + `helpers` (surface `workbench` ledger
  rows), each also given separately, plus `analytics_off` = workbench names with analytics off
  (their sessions are not counted).
- `page_total`: Watchtower + own automations + chats (what Home shows).
- `ledger_since` (first row's time) so the screen can say when recording started.

The command is **read-only**: it opens the database with `db.OpenExisting` (no migrations, no
writes) and never imports the spool. A missing database file or a missing `llm_calls` table
(checked in `sqlite_master` before querying — the app not yet migrated) is not an error: the
ledger part is empty and `ledger_since` is `""`, so the tab shows "Recording starts with the
next AI call" instead of an error. It aggregates the table and adds
the spool's not-yet-imported lines (and a leftover `.importing` file) in memory, de-duplicated
by `call_id`, so the numbers are current without a second writer.

JSON keys are pinned by a test, like other `--json` commands.

### 6. Desktop: Usage → **Watchtower** tab

New segment in `UsageView` (`Claude plan | Watchtower | Progress | Usage`), built from the
design kit (mockup: [docs/design/mockups/llm-usage/index.html](../../design/mockups/llm-usage/index.html)):

- Period picker: `KitSegmentedPicker` Today / 7 days / 30 days (remembered in `@AppStorage`).
- Totals row (`Card`): calls, fresh input, cache, output, cost; one grey line under it naming
  every gap that is non-zero — estimated-usage calls, calls without a price, untagged calls.
- Table by process ("Watchtower collecting and processing", incl. built-in automations),
  sorted by cost (tokens when cost unknown): display name, calls, total tokens, output, cost,
  per call. Display names come from a purpose → name/group map in WatchtowerCore with the raw
  purpose as fallback. Untagged rows are always last, in the warning colour,
  when present.
- **Your automations** section: subtotal + one row per owner automation.
- **Chats and workbenches** block: one line for chats, one line for workbenches (secondary
  text: "sessions X · Watchtower helpers Y"); a note under it when some workbenches have
  analytics off.
- Screenshots: a `DesignShotCatalog` entry for the tab with fixture data (all gap lines on),
  checked with `make desktop-shots` before review, per the style guide.
- Data from `usage llm --json` through the CLI runner, refreshed on appear and every 60 s
  while visible.
- Empty state: "Recording since <date>" until the first row exists.

The guide's Usage text (`docs/guide/concepts/ai-providers-and-cost.md` and
`troubleshooting/plan-limits-or-high-cost.md`) gets the new tab; a feature note
`docs/features/llm-usage-ledger.md` and its CLAUDE.md line.

## Decisions

- Ledger of every LLM call + Watchtower tab + one total for chats and workbenches; `pipeline_runs`
  untouched — ask #672.
- Proposed by Claude, **not yet answered by the owner**; the owner's approval of this spec is
  what confirms them, and each can be changed in the review comments (review asks #673/#674
  and later rounds):
  - Watchtower's calls made for workbench features (review overview, spec review, terminal
    titles, workbench MCP tools) are counted under workbenches, not in the Watchtower table.
  - Workbench session totals come from agent analytics and cover only workbenches with
    analytics on; the screen names the ones left out.
  - Built-in automations count as Watchtower's own work; the owner's automations are a
    separate "Your automations" section, outside the Watchtower subtotal.
  - Ledger retention 90 days.
  - The old Usage tab **and the Progress tab** stop showing tokens and cost and point to the
    Watchtower tab.
  - Every non-daemon process writes through the spool; the daemon is the only ledger writer;
    `usage llm` is read-only and merges the spool in memory; a failed spool write falls back to
    a direct insert, then to the log line. (Written in answer to the owner's comments in
    ask #677, which pointed at the problems; the choice itself is confirmed by approving this
    spec.)
  - Home's "AI spend" = `page_total` from `usage llm` (Watchtower + your automations + chats).
- Home's "AI spend" must come from the ledger, not `pipeline_runs` — owner comment, ask #677.

## Calls left to the builder

- Exact display-name map and grouping of purposes.
- How the guard test recognises a leaf (AST over method sets vs. a curated list checked against
  `go/packages`), as long as a new non-recording leaf fails it.
- Whether `agentlog.Cost` moves to a shared package or is imported.

## Verification

- Unit tests per leaf: a fake CLI/HTTP response with known usage → exactly one row with the
  right split and cost; a failed call → one row with `ok = 0`; wrappers add no rows.
- `TestLLMUsageLeaves` guard.
- Spool tests: a non-daemon process spools; the daemon import moves every line exactly
  once, including lines appended during the import and after a crash mid-import; an unwritable
  spool falls back to the direct insert, and with both failing writes the log + stderr line;
  `usage llm` writes nothing to the database (opened read-only) and still counts spooled
  calls once.
- Automation reconciliation test: an automation run with `llm()` and `agent()` calls → the
  ledger rows with its `automation_run_id` sum to the run's `automation_runs` tokens.
- Lock cost: one ledger insert is an autocommit single-row write after a call that takes
  seconds; acceptance = no `llm_calls` call site over the 200 ms threshold in `dblock.jsonl`
  during the manual check below.
- UI checks (shots + tests): the run-log tab and Progress show no token or cost numbers and
  carry the pointer line; Home's AI spend equals `page_total` of `usage llm --since today`
  (fake CLI runner in the test, and once by hand on the installed build).
- `usage llm` on a database without `llm_calls` and with no database file → exit 0, empty
  ledger part, `ledger_since: ""`.
- Manual cross-check on the owner's install after one day, per path:
  - daemon: ledger rows with `process = daemon` vs the generator calls in `sessions.log` for
    the same window;
  - automations: per run, ledger sum vs `automation_runs` tokens;
  - CLI: run `watchtower ask "…"` and one `jira` AI command → exactly one new row each, with
    the right purpose;
  - chat: one main-chat turn and one embedded-chat turn → one `chat` row each;
  - the Watchtower total moves the Claude plan meter in the same direction.
