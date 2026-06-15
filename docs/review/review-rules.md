# Review Rules

> **Priority 0 — does the change actually work?** Before any style/DRY/architecture critique,
> every reviewer must first establish that the change **does what it is supposed to do**: it
> builds (`make build`, and `swift build` if Desktop changed), `go vet` and `make lint` are
> clean, the tests it adds actually exercise the real behaviour and would fail if it broke, and
> they run green under `go test ./... -race` rather than racing, false-greening, or depending on
> an un-mocked AI subprocess. A beautifully-styled change that does not verify working behaviour
> fails review. Weigh dimension **6 (AC correctness)** and **7 (test quality)** first; everything
> else is secondary.

Project-specific binding review rules, assembled over time from merged PRs and `debate-review`
reflections. Every review agent (advocate, prosecutor, codex, judge, style-guardian) reads this
file. Empty sections are fine — agents fall back to the dimension definitions in
`.claude/skills/debate-review/references/agent-prompts.md` plus `CLAUDE.md` and `docs/inventory/`
until rules are filled in here.

Format: under each dimension, one bullet per rule. Keep each rule concrete and testable (a
reviewer should be able to point at code and say pass/fail). Cite the PR or lesson it came from.

## 1. Architecture style

- New backend code lives in `internal/<domain>/`; cross-cutting seams go through interfaces (`ai.Provider`, `digest.Generator`) so they stay mockable in tests. (seed)
- Desktop code follows Models → Queries → ViewModels (`@MainActor`, `@Observable`) → Views; UI reads SQLite through GRDB `ValueObservation`, never raw SQL in a View. (seed)
- A daemon pipeline phase added/reordered must preserve the documented phase order (detectors → classifier → AI prioritize → … → unsnooze); do not insert a phase that depends on later output. (seed, see CLAUDE.md Inbox Pulse)

## 2. Architecture decision correctness

- Do not add a speculative export (function, type, interface, CLI flag) with no caller in the same change; defer it until something needs it. (seed)
- Reuse the existing pipeline/table for a domain instead of spinning up a parallel one; extend `digest.Generator` / the existing detector rather than duplicating the flow. (seed)
- Never force a full Slack sync on first run — search/incremental sync handles a fresh DB; full sync on a large workspace takes hours. (seed, CLAUDE.md Sync Architecture)

## 3. Code style

- Wrap returned errors with `%w` and enough context to locate the call site; no bare `return err` that loses the operation. (seed)
- Go names are idiomatic and stutter-free (`inbox.Item`, not `inbox.InboxItem`); `gofmt` is clean. (seed)
- Use "polling" (not "pooling") in retry/wait helper identifiers. (seed)

## 4. Solution efficiency

- Batch SQLite writes / avoid N+1 queries in pipeline loops; load once and index in memory where a per-row query would otherwise run. (seed)
- Do not add work to the hot sync path that a daemon phase already does (e.g. re-deriving inbox state the detector already wrote). (seed)

## 5. Codebase fit

- Tests reuse the established helpers: mock `digest.Generator` (never call the live `claude`/`codex` subprocess), `baseMux()` / `messageMux()` for Slack API stubs, the shared query layer. (seed)
- For TCC isolation use `--setting-sources project,local`; never set `CLAUDE_CONFIG_DIR` (any value breaks keychain auth → "Not logged in"). (seed, memory)

## 6. Requirement correctness (AC)

- A change that claims to fix a bug must add a test that fails on the pre-fix code and passes after — not just a green happy-path test. (seed)

## 7. Test quality + race risk

- `:memory:` SQLite DBs must set `SetMaxOpenConns(1)` — otherwise a transaction opens a fresh, empty connection and the test false-greens or panics. (seed, CLAUDE.md)
- Tests needing a custom `conversations.history` handler use `baseMux()`, not `defaultMux()` — Go 1.25 panics on duplicate `HandleFunc` registration. (seed, CLAUDE.md)
- The AI generator is mocked in tests; a test must never shell out to the real `claude`/`codex` CLI. (seed)
- `docs/inventory/` guard tests (`Test<Module>NN_`) are load-bearing: do NOT weaken their assertions, rename them out of the convention, or split them into weaker tests. A change that needs to is **stop-and-ask-the-owner**. (seed, CLAUDE.md Behavior Inventory)
- New behaviour gets a `-race`-clean test; a data race that only appears under `-t race` is a blocker, not a flake. (seed)

## 8. Regression / blast radius

- DB schema migrations are forward-only and versioned; bumping the schema version requires the migration plus updated Swift `FetchableRecord`/`Codable` models that read the new shape. (seed)
- Changing a public Go interface (`ai.Provider`, `digest.Generator`) or a CLI flag updates every implementation/consumer in the same change; keep the old form if back-compat is needed. (seed)

## 9. DRY + error handling + security

- A swallowed error (caught/ignored without log or return) is a blocker unless it is a documented known-safe idempotency case (e.g. already-resolved); rethrow/return everything else so it surfaces. (seed)
- No committed credentials, Slack/Google tokens, or machine-absolute paths (`/Users/...`); load secrets from config/keychain and gitignore token files. (seed)
- A macOS TCC prompt triggered by `Watchtower.app` is a **P0**: fix the responsibility chain (e.g. `responsibility_spawnattrs_setdisclaim` in the daemon spawn path), never suppress the symptom or blame the source CLI. (seed, memory)
- SQL is parameterised; never string-concatenate user/Slack data into a query. (seed)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
