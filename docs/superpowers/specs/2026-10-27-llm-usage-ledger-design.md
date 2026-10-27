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

- No change to `pipeline_runs` or the existing **Usage** run-history tab (it stays the run
  log; its token columns are not fixed in this work).
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
| `at` | RFC 3339 UTC finish time |
| `surface` | `watchtower` \| `chat` \| `workbench` |
| `purpose` | the ctx source tag (`digest.channel`, `automation.llm`, …), `''` = untagged |
| `process` | the process kind + command path: `daemon`, `cli:jira boards`, `mcp:workbench`, `ai session`, … |
| `provider` | `claude` \| `codex` \| `ollama` \| `http` (runtime B) |
| `model` | model id as the provider reported it, else the requested one |
| `input_tokens` | fresh (uncached) input |
| `cache_read_tokens`, `cache_write_tokens` | prompt cache |
| `output_tokens` | output |
| `usage_estimated` | 1 when the provider reported no usage and the tokens are length/4 |
| `reported_cost_usd` | the provider's own cost (Claude CLI `total_cost_usd`), NULL when none |
| `est_cost_usd` | price-table estimate, NULL when the model has no price |
| `duration_ms` | wall time of the call |
| `ok` | 1 success, 0 error |
| `automation_id` | the automation run's automation, NULL otherwise |

Indexes on `at` and `(surface, at)`. Rows older than 90 days are deleted once a day by the
daemon. Mirrored into `schema.sql`, `TestAllTablesExist`, golden + Swift test schema (CLAUDE.md
migration rules).

### 2. Recording point: `internal/llmusage`

A leaf package (no imports of digest/ai/codex) with:

- `Call` struct (the columns above minus `id`, `at`, `surface`, `process` which the sink fills).
- context helpers: `WithPurpose`/`PurposeFrom`, `WithSurface`/`SurfaceFrom`,
  `WithAutomation`/`AutomationFrom`. `digest.WithSource`/`SourceFromContext` become thin
  wrappers over `WithPurpose`/`PurposeFrom`, so the ~60 existing tagged call sites are tagged
  for the ledger without edits.
- `Record(ctx, Call)` — hands the row to the process's installed `Sink`; with no sink it
  counts the call in a process-wide "unrecorded" counter and writes one stderr line per
  process (`llmusage: no sink, N calls not recorded`).
- `SetSink(Sink)` — installed by `cmd` for every command that opens the database, with the
  process string. The DB sink writes one short `INSERT` (its own autocommit, never inside a
  caller's transaction), logs and drops on error.

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
  - Automations stay `watchtower` (they are Watchtower working for the owner), with
    `automation_id` set; workbench-scoped automations stay `watchtower` too in v1 *(builder's
    call to revisit if the numbers look odd)*.
- `ai test` (provider ping) gets purpose `probe`.

### 4. Cost

- `reported_cost_usd` = what the provider reported (Claude CLI). The Claude CLI reports an
  API-equivalent price even on a subscription; the screen labels the column "API-equivalent $".
- `est_cost_usd` = `agentlog.Cost` (moved or re-exported to a shared place) at record time;
  the price table gets alias resolution for the short names Watchtower passes (`opus`,
  `sonnet`, `haiku`). Codex/Ollama models have no price → NULL, shown as "—".
- The screen shows reported cost when present, else the estimate prefixed with "≈".

### 5. CLI: `watchtower usage llm`

`watchtower usage llm [--since 1d|7d|30d] [--json]` aggregates in Go (single source of truth
for the screen and the terminal):

- `watchtower`: totals (calls, errors, input, cache read, cache write, output, cost,
  estimated-usage calls, cost-unknown calls) and `by_purpose` rows (purpose, display group,
  calls, tokens, cost, avg tokens per call, models), automations broken down by automation name.
- `chats`: one totals object (surface `chat`).
- `workbenches`: `helpers` (surface `workbench` ledger rows) and `sessions` (agent sessions
  from `agentlog.db` events in the period, workbenches with agent analytics on), plus
  `analytics_off` = workbench names with analytics off (their sessions are not counted).
- `unrecorded_note` when the ledger is younger than the period ("ledger started <date>").

JSON keys are pinned by a test, like other `--json` commands.

### 6. Desktop: Usage → **Watchtower** tab

New segment in `UsageView` (`Claude plan | Watchtower | Progress | Usage`), built from the
design kit:

- Period picker: Today / 7 days / 30 days (remembered in `@AppStorage`).
- Totals row: calls, fresh input, cache, output, cost; small grey line for estimated / untagged
  calls when non-zero.
- Table by process, sorted by cost (tokens when cost unknown): display name, calls, total
  tokens, output, cost, per call. Display names come from a purpose → name/group map in
  WatchtowerCore with the raw purpose as fallback; automations show their names. Untagged is
  always listed last, in a warning colour, when present.
- **Chats and workbenches** block: one line for chats, one for workbench sessions, one for
  Watchtower's workbench helpers; a note under it when some workbenches have analytics off.
- Data from `usage llm --json` through the CLI runner, refreshed on appear and every 60 s
  while visible.
- Empty state: "Recording since <date>" until the first row exists.

The guide's Usage text (`docs/guide/concepts/ai-providers-and-cost.md` and
`troubleshooting/plan-limits-or-high-cost.md`) gets the new tab; a feature note
`docs/features/llm-usage-ledger.md` and its CLAUDE.md line.

## Decisions

- Ledger of every LLM call + Watchtower tab + one total for chats and workbenches; `pipeline_runs`
  untouched — ask #672.
- Watchtower's calls made for workbench features (review overview, spec review, terminal titles,
  workbench MCP tools) are counted under workbenches, not in the Watchtower table — conversation
  (Claude's call, stated to the owner).
- Workbench session totals come from agent analytics and cover only workbenches with analytics
  on; the screen says so — conversation (Claude's call, stated to the owner).

## Calls left to the builder

- Exact display-name map and grouping of purposes.
- How the guard test recognises a leaf (AST over method sets vs. a curated list checked against
  `go/packages`), as long as a new non-recording leaf fails it.
- Whether `agentlog.Cost` moves to a shared package or is imported.
- Batching of ledger inserts if a hot path shows lock waits in `dblock.jsonl` (v1: one insert
  per call).

## Verification

- Unit tests per leaf: a fake CLI/HTTP response with known usage → exactly one row with the
  right split and cost; a failed call → one row with `ok = 0`; wrappers add no rows.
- `TestLLMUsageLeaves` guard.
- Manual cross-check on the owner's install after one day: the number of ledger rows with
  `process = daemon` equals the generator calls in `sessions.log` for the same window, and the
  Watchtower total moves the Claude plan meter in the same direction.
