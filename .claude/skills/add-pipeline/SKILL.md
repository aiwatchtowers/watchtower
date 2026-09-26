---
name: add-pipeline
description: Use when adding a whole new AI-powered feature/pipeline to Watchtower end-to-end — a new internal/<feature>/ Go package with a Run() pipeline, its daemon phase + CLI command, and (optionally) the matching Desktop tab. Orchestrates the focused add-migration, add-ai-prompt, and add-desktop-feature skills.
---

# Add a Pipeline End-to-End (Watchtower)

A feature like digest / tracks / inbox / catchup is built in layers in a fixed order. This skill is the spine; it delegates the data and AI details to the focused skills. Copy **`internal/catchup/`** as the template (newest, complete: gather → outline → expand + feedback).

## Order of work

1. **Data first.** If the feature needs tables/columns, do the migration before anything reads them → **[[add-migration]]**.

2. **Go package** `internal/<feature>/`:
   - `pipeline.go` — `type Pipeline struct{ db *db.DB; cfg *config.Config; generator digest.Generator; logger *log.Logger }`, constructor `func New(db, cfg, gen, logger) *Pipeline`, and `func (p *Pipeline) Run(ctx) (..., error)`.
   - `prompt.go` — system prompts + user-message builders. `types.go` — AI response structs + parsers. `learn.go` — only if it takes operator feedback.
   - Always accept `digest.Generator` by interface so tests inject a mock — never construct a Claude/Codex client inside the package.

3. **AI calls** inside the pipeline → **[[add-ai-prompt]]** (prompt registration, `digest.WithSource` tagging, model tier, both-provider correctness).

4. **Daemon wiring** (`internal/daemon/daemon.go`): add a field to `Daemon`, a `SetXPipeline(p *X.Pipeline)` setter, and invoke it from the right phase in `Run` (phase order is documented in CLAUDE.md / the `phaseXxx` methods — slot it by its dependencies: after digests if it consumes them, etc.).

5. **Daemon init** (`cmd/sync.go`): build the pipeline behind its config flag and register it — `if cfg.X.Enabled { d.SetXPipeline(x.New(database, cfg, gen, logger)) }` — reusing the shared `gen, cleanup := cliPooledGenerator(cfg, logger)`.

6. **CLI command** (`cmd/<feature>.go`): cobra `Cmd` + subcommands, `init()` → `rootCmd.AddCommand`, and a factory that does `config.Load` → `applyProviderOverride(cfg)` → `db.Open` → `cliPooledGenerator` → `feature.New(...)`. Copy `cmd/catchup.go`.

7. **Config** (`internal/config/config.go`): add a `XConfig` block with an `Enabled bool`; defaults in `internal/config/defaults.go`.

8. **Tests** (`internal/<feature>/pipeline_test.go`): `db.OpenTestDB(t)` + a `mockGenerator` (record `called`, optional `fn` for dynamic responses), seed fixtures, assert pipeline output AND DB state. Name guard tests `Test<Feature>NN_...` if covered by `docs/inventory/`.

9. **Desktop tab** (optional) → **[[add-desktop-feature]]**.

10. **Gate:** run **`local-review`** before any PR.

## Gotchas

- **Generator is injected, period.** Hardcoding a provider client breaks mockability and both-provider support.
- **Phase placement matters** — a pipeline that reads digests must run after `phaseChannelDigests`; one that feeds the briefing must run before `phaseBriefing`.
- **Go 1.25 panics on duplicate `HandleFunc`** in test muxes — custom `conversations.history` handlers use `baseMux()`, not `defaultMux()` (see `internal/sync/orchestrator_test.go`).
- **Always `defer cleanup()`** the pooled generator, or you orphan CLI subprocesses.
- **`applyProviderOverride(cfg)` before building the generator**, or `--provider` is ignored.
- **Fan-out AI calls** must bound concurrency on `cfg.AI.Workers` (semaphore) — see catchup's per-theme expand.

## Reference (copy from)
Pipeline: `internal/catchup/` (also `internal/inbox/`, `internal/tracks/`, `internal/digest/`) · daemon: `internal/daemon/daemon.go`, init in `cmd/sync.go` · CLI: `cmd/catchup.go` · tests: `internal/catchup/pipeline_test.go`, mux pattern in `internal/sync/orchestrator_test.go`
