# LLM usage ledger — what Watchtower spends on AI, per call (2026-10-27, board #1169)

Spec: `docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md`. Plan: `docs/superpowers/plans/2026-10-27-llm-usage-ledger.md`. Contract: LLMUSAGE-01 in `docs/inventory/plan-usage.md`.

## Summary

Every model call made by a Watchtower Go process is one row in `llm_calls` (`watchtower.db`, migration 00163): who asked (`purpose`), for whom (`surface`), which process, provider and model, the full token split (fresh input, cache read, cache write 5 m / 1 h, output), the provider's own cost when it reports one and a price-table estimate otherwise. `pipeline_runs` is untouched; its token columns were wrong (uncached input only, cost always 0, only opt-in call sites) and the screens that read them stopped showing tokens and cost. Usage → **Watchtower** and `watchtower usage llm` read the ledger; Home's "AI spend" is the CLI's `page_total`.

## Recording

`internal/llmusage` is a leaf package (no imports of digest/ai/codex). `Record(ctx, Call)` fills the call id (16 random hex chars, UNIQUE), time, surface, purpose, process and automation ids, then hands the row to the process's writer. Recording is best-effort and never changes a call's result.

- **Context tags.** `WithPurpose`/`PurposeFrom` (`digest.WithSource`/`SourceFromContext` are thin wrappers, so the ~60 tagged call sites needed no edit), `WithSurface`/`SurfaceFrom`, `WithAutomation`/`AutomationFrom`. A call with no purpose is stored with `purpose = ''` and shows as Untagged with its `process`. `ai test` and `ValidateModel` probes use purpose `probe`.
- **Surface** defaults from the process role (`cmd/process_role.go` `surfaceFor`, set by `llmusage.SetProcess` in the root pre-run): `chat` for `ai session`, `ai query` and `mcp --chat` (not `--surface automation`); `workbench` for `mcp --workbench`, `workbench …`, `terminal …` and `hook:*`; everything else, the daemon and an automation's `agent()` server included, is `watchtower`. A context surface overrides it.
- **Automations.** `WithAutomation` is set once at `Env.MeteredModelCall`, which covers `llm()`, `agent()` and the built-in primitives, so each call carries `automation_id` and `automation_run_id` (inline built-in runs carry a real run id). The reconciliation test sums the rows of a run against `automation_runs`.
- **Cost.** `reported_cost_usd` = the Claude CLI's `total_cost_usd` (an API-equivalent price, also on a subscription); `est_cost_usd` = `agentlog.Cost` with alias resolution for `opus`/`sonnet`/`haiku`, NULL for models with no price (Codex, Ollama). A provider that reports no usage gives length/4 tokens with `usage_estimated = 1`. A reported cost of 0 counts as missing.
- **Chats.** The warm `ai session` child reports `total_cost_usd` and `modelUsage` cumulatively per child process, so `ClaudeTranslator.recordTurn` records the **per-turn** cost as the difference from the previous result line; `usage` is already per turn. Chat turns keep purpose `''` (the surface says what they are).

### Leaves

Only leaf implementations record, wrappers (`PooledGenerator`, `timeoutGenerator`, `policyChecked*`) never do, so nothing is counted twice: `digest.ClaudeGenerator` `Generate`/`GenerateWithImage` (after `cliUsageOf`, with the cache split), `codex.CodexGenerator.run`, `ollama.Generator.Generate`, `ai.Client.QuerySync`/`Query` (the stream's final result event), `codex.Client.QuerySync`/`Query`, `ollama.Client.QuerySync`/`Query` (`stream_options.include_usage`), `agentloop` `meteredChat` (per model call), `chat.ClaudeTranslator` (per `result` line) and the probes.

### Spool contract

- The **daemon** installs the database `Sink` and writes its rows straight to `llm_calls` (autocommit single-row `INSERT`, never inside a caller's transaction, measured by lockmetrics like every write). It is the only regular writer of the table.
- **Every other process** appends one JSON line to `<workspace>/llm_calls.spool.jsonl` (0600; numbers, purpose, process and model only, no prompt or response text, FILES-01). A process that cannot resolve a workspace (no config, or a config with no active workspace) writes the **setup spool** under the data root instead; the spool append creates its directory (0700).
- `phaseLLMLedger` at the start of each cycle imports the workspace spool, then the setup spool: rename to `.importing` under the sidecar flock `llmusage.LockSpool(path)` (shared by the writer and `db.ImportLLMSpool`, so a line appended meanwhile is not lost), `INSERT OR IGNORE` on `call_id` (a crash between insert and delete imports nothing twice), then delete. The first daemon to rename the setup spool claims its lines for its workspace, exactly once. A line failing the table's CHECK is skipped, not stalled on. The same phase prunes rows older than 90 days once a day.
- **Spool write fails** (disk full, permissions): immediate fallback to a direct `INSERT` into the workspace database (opened lazily by path, existing file, no migration, 2 s busy wait; the only exception to "the daemon writes the table"); if that fails too, one line `llmusage: call not recorded (<purpose>, <process>): <error class>` goes to the workspace's (or the data root's) `watchtower.log` and to stderr.
- `llmusage.Record` returns nothing to the caller on any failure.

### Guard

`internal/llmusage/leaves_test.go::TestLLMUSAGE01_LeavesRecord` (LLMUSAGE-01) parses `cmd/` and `internal/`: every process start (`exec.Command*`, `os.StartProcess`, `syscall.Exec`, `pty.Start*`) and every HTTP request in a package that names an LLM endpoint literal must sit in a function that records (directly or through a same-package `record*` helper), or be in `knownNonLLMExec` / `knownNonLLMHTTP` with a reason; a stale entry fails too. Function literals count toward their enclosing declaration. `TestLLMUsageLeavesCatchesNewLeaf` runs the checker over `testdata/leaves` so a regression in the checker itself is caught.

## `watchtower usage llm [--since today|7d|30d] [--json]`

Read-only (`db.OpenExisting`, no migration, no write, never imports the spool): it aggregates the table and adds the spool's not-yet-imported lines (and a leftover `.importing`) in memory, de-duplicated by `call_id`. A missing database file or a missing `llm_calls` table is not an error: the ledger part is empty and `ledger_since` is `""`. Spool rows with a surface outside `watchtower|chat|workbench` are dropped, as the importer does. `today` is local midnight; default `7d`.

Pinned JSON keys: top level `period`, `ledger_since`, `watchtower`, `own_automations`, `chats`, `workbenches`, `page_total`. Every totals object: `calls`, `errors`, `estimated_calls`, `no_price_calls`, `untagged_calls`, `input`, `cache_read`, `cache_write`, `output`, `cost_usd` (null when no call had a cost), `cost_is_estimate`, `cost_is_lower_bound`. `watchtower`: `totals` + `rows` (`purpose`, `process` on untagged rows only, `models` always an array of strings, `calls`, `input`, `cache_read`, `cache_write`, `output`, `cost_usd`, `cost_is_estimate`, `cost_is_lower_bound`, `per_call_tokens`). `own_automations`: `totals` + `rows` (`automation_id`, `name`, `runs`, `calls`, `input`, `output`, `cost_usd`, `cost_is_estimate`). `workbenches`: `totals`, `sessions` (totals + `sessions` count), `helpers` (always objects), `analytics_off` (workbench names). `page_total` = Watchtower + own automations + chats; workbenches are not in it.

Sections, each call in exactly one: **Watchtower** (surface `watchtower`, built-in automations included), **Your automations** (origin `owner`, any surface, a workbench-scoped one included, so its spend does not show under workbenches), **Chats** (surface `chat`), **Workbenches** = `sessions` (agent sessions from `agentlog.db`, only workbenches with agent analytics on, priced from tokens so always an estimate) + `helpers` (surface `workbench` ledger rows: review overview, spec review, terminal titles, workbench MCP tools).

## Desktop

- Usage → **Watchtower** tab (`LLMUsageViewModel`, data from `usage llm --json` through the CLI runner, refreshed on appear and every 60 s; period picker Today / 7 days / 30 days kept in `@AppStorage`): totals card with one grey line naming every non-zero gap (estimated usage, no price, untagged), the process table (display names from `LLMPurposeNames` in WatchtowerCore with the raw purpose as fallback, Untagged last in the warning colour), Your automations, and the Chats and workbenches block. Cost shows "≈" for an estimate and "≥" for a lower bound. Before the first row: "Recording starts with the next AI call".
- The old **Usage** run-history tab and **Progress** drop their token and cost numbers and carry the one-line pointer "Tokens and cost: see the Watchtower tab".
- Home → Numbers **AI spend**: `page_total` of `usage llm --since today --json` (no second implementation in Swift), "—" while loading and on failure (never $0), refreshed when Home appears and every 5 min while visible, opens Usage → Watchtower.

## v1 limits

- A call lost on both the spool and the fallback leaves only the `watchtower.log` line and stderr; when the log append fails too (the disk is the usual cause of all three) only stderr. The screen cannot count these.
- An interrupted chat turn loses its streamed tokens: usage arrives with the `result` line, which an interrupt never produces.
- Workbench session totals are estimates priced from agent-analytics tokens and cover only workbenches with analytics on; the screen names the ones left out.
- The table reads run in one read-only snapshot and the spool is read live file first, then `.importing`, without a lock; a daemon import racing the read can only make a call appear in both, which the `call_id` de-duplication removes.
- Retention is 90 days; the screen's longest period is 30.

### Guard blind spots

`TestLLMUSAGE01_LeavesRecord` checks that code records, not that it is wired:
- **HTTP residual risk.** An HTTP leaf in a package with none of the endpoint literals in `llmEndpoints` (`/chat/completions`, `/v1/messages`, `/api/chat`, `/api/generate`, `/responses`) is not checked.
- **Process starts it cannot see.** `&exec.Cmd{…}` struct literals, starts through a function-typed parameter or field, and a *new* start added to a function already on a list or already recording (the function passes, the new start is unrecorded).
- **Wiring.** `Execute` wires every process to the setup spool (and the data root's `watchtower.log`) before cobra runs; `wireLLMUsage` in the root `PersistentPreRunE` then points it at the resolved workspace. A command with its own no-op `PersistentPreRunE` (hooks, `session-host`, `guide`, …) keeps the setup spool, which the first daemon cycle of any workspace claims, so its calls are never lost to "no spool"; the guard checks recording, not wiring.
- `record*` helpers are matched by bare name inside the package; the lists are keyed by package name, not import path.
- `usage llm` "never writes" depends on the root pre-run's `ensureSchemaFormat`, which may rewrite the config on an old `schema_format` (true of every command).

## How to extend

A new LLM call: use an existing leaf (it records) and tag the context with `digest.WithSource`/`llmusage.WithPurpose`; add its display name in `LLMPurposeNames`. A new leaf (a new provider, a new process start that runs a model): record from its usage funnel, and the guard fails until it does. A new non-LLM process start: list it in `knownNonLLMExec` with a reason.
