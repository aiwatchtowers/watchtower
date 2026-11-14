# Watchtower — Developer Notes

**Project:** `watchtower` (Go module: `watchtower`)
**Backend:** Go 1.26, SQLite via an in-repo SQLCipher build of `mattn/go-sqlite3` (`internal/sqlcipher`, cgo; `database/sql`), see `go.mod` and `internal/sqlcipher/VERSION`
**Desktop:** SwiftUI macOS app (Swift 5.10 language mode, macOS 14+; building requires a Swift 6+ toolchain / Xcode 16+ — the FluidAudio dependency's manifest declares swift-tools 6.0), GRDB.swift through our SQLCipher fork (`aiwatchtowers/GRDB.swift`, pinned exactly; the Kit and the phone use the same pin), see `WatchtowerDesktop/Package.swift`
**Mobile (POC):** shared Swift package `WatchtowerKit/` (`WatchtowerSync` + `WatchtowerKit`, macOS 14 / iOS 17) and the iPhone app `WatchtowerMobile/` (SwiftUI, iOS 17+, xcodegen `project.yml` with the generated `.xcodeproj` committed), see `docs/features/mobile-companion.md`

---

## Feature Notes

Per-feature notes — architecture, contracts, dual paths, v1 limits — live in `docs/features/`; read the relevant file before touching that area. [docs/features/README.md](docs/features/README.md) carries a one-paragraph summary of every note (key types, migrations, CLI verbs, contract ids) — grep it when you do not know which note covers a name. A new note adds a line here and its summary there; a change that overturns a summarised contract updates the summary.

- Onboarding v2 — `onboarding-v2.md`
- First run — `first-run.md`
- Connections tab — `connections-tab.md`
- Learn Watchtower — `learn.md`
- History backfill — `history-backfill.md`
- Automations — `automations.md`
- Built-in automations — `built-in-automations.md`
- Inbox cards with a layout — `inbox-card-blocks.md`
- Claude ↔ Codex quota routing — `provider-fallback.md`
- LLM usage ledger — `llm-usage-ledger.md`
- SQLite write-lock metrics — `db-lock-metrics.md`
- Subscription plan limits — `claude-plan-limits.md`
- Agent analytics — `agent-analytics.md`
- In-app help — `in-app-help.md`
- Attention detection — `attention-detection.md`
- Inbox folders — `inbox-folders.md`
- Source deletions and edits — `source-deletions.md`
- Revoked access wipes the account's data — `revoke-purge.md`
- Images and web links become knowledge — `media-knowledge.md`
- Corporate policy through managed preferences — `mdm-policy.md`
- Bulk-read limits + audit log — `bulk-read-limits.md`
- Knowledge search — `knowledge-search.md`
- Confluence knowledge connector — `confluence-knowledge-connector.md`
- Confluence page editing from the chat — `confluence-page-editing.md`
- HTML artifacts and previews — `html-artifacts.md`
- Embedded assistant chats — `embedded-chat.md`
- Chat Redesign — `chat-redesign.md`
- Chat — claude.ai tools — `chat-claude-ai-tools.md`
- Slack send from the chat and the workbench terminal — `slack-send.md`
- Workbench — `workbench.md`
- Agent instructions — `agent-instructions.md`
- Agent coach — `agent-coach.md`
- Tuning chat — `tuning-chat.md`
- Spec review — `spec-review.md`
- Session chat feed — `session-chat-feed.md`
- Diff reviewer / Branch review — `diff-reviewer.md`
- Mobile companion — `mobile-companion.md`
- Relay client — `relay-client.md`
- Go hub — `go-hub.md`
- Code navigation in the workbench code viewer — `code-navigation.md`
- Catch-Up — `catchup.md`
- Meeting Transcriber — `meeting-transcriber.md`
- Private meetings and transcript export — `private-meetings.md`
- Memory — `memory.md`
- Google Multi-Account — `google-multi-account.md`
- Slack Multi-Account — `slack-multi-account.md`
- Slack Live — the owner's own Claude/ChatGPT Slack connector — `slack-live.md`
- Jira Multi-Account — `jira-multi-account.md`
- Jira status history + time in status — `jira-changelog.md`
- Jira custom fields discovery & mapping — `jira-custom-fields.md`
- Linear connector — `linear.md`
- Model & Provider Registry — `model-provider-registry.md`
- Adding a harness (LLM transport or session agent) — `adding-a-harness.md`
- Menu-Bar Tray + Daemon Lifecycle + CLI Binary Store — `tray-daemon-lifecycle.md`
- Database compaction at launch — `db-compact.md`
- Database encryption — `db-encryption.md`
- Watchtower data out of Time Machine — `time-machine-exclusion.md`
- Files outside the database — `files-outside-db.md`
- Ideas & Decisions Registry — `ideas-decisions-registry.md`
- Developer Surface — `developer-surface.md`
- Feature Manager — `feature-manager.md`
- Voice Dictation — `voice-dictation.md`
- Target Brief Chat — `target-brief-chat.md`
- Persona Merge — `persona-merge.md`
- Agent Actions — `agent-actions.md`
- Quick Connections — `quick-connections.md`
- Reaction Commands + Inbox Action Strip — `reaction-commands.md`
- Strong-tier cost fixes — `strong-tier-cost-fixes.md`
- Audit fix wave 5 — `audit-fix-wave-5.md`
- Owner identity — `owner-identity.md`

---

## User guide

The user-facing guide lives in `docs/guide/` (start at `docs/guide/README.md`). A user-facing change updates its page in the same PR, following `docs/guide/WRITING.md`. `docs/app-guide.md` is gone.

---

## Build & Test

**Inner loop (while iterating — this is the default, full runs are NOT):**
- Go: test only the touched package — `go test ./internal/<pkg>` (add `-run TestName` to narrow further). The Go build/test cache makes this seconds; never add `-count=1` reflexively, it defeats the cache. The first `go test` after a clean cache compiles the SQLCipher amalgamation (~30 s); `CGO_ENABLED=0` no longer builds.
- Swift: always filter — `make test-swift FILTER=<TestClass>` (a regex alternation such as `FILTER='ClassA|ClassB'` works too — the recipe quotes it) (or `cd WatchtowerDesktop && swift test --filter <TestClass>`). An unfiltered `swift test` re-links the whole ML stack and belongs to the gate only. Core-level code lives in `WatchtowerCore` and its tests in `Tests/Core`, which build without the ML stack — prefer testing there when touching Models/Database/pure Services (measured ~0:12 edit→test vs the ~0:35 pre-split baseline; see `docs/superpowers/specs/2026-08-11-local-build-speed-design.md`'s Phase 2 appendix — the shared test bundle still links ML at run time, so the win is in compile time, not in avoiding the link).
- Mobile Kit: `make kit-test FILTER=<TestClass>` (`WatchtowerKit/`, no ML stack); an unfiltered `make test-swift` runs the Desktop suite and then the whole Kit suite.
- iPhone app: `make mobile-build`, `make mobile-test MOBILE_FILTER=<TestClass>` (simulator `SIM`, default `iPhone 18 Pro`; override with one your Xcode has), `make mobile-gen` after editing `WatchtowerMobile/project.yml`. Builds are unsigned; tests are signed to run locally with the test-only `WatchtowerMobile/StoreKitTesting.entitlements`; device and archive signing come from the gitignored `WatchtowerMobile/Signing.xcconfig`.
- Lint: `make lint-diff` (issues introduced vs origin/main). Full `make lint` is the gate.

**Gate (before a PR):** full `make test`, `make test-swift` (includes the Kit), `make lint-all` (lints the Desktop, Kit and phone trees); with phone changes also `make mobile-test`.

**Cache hygiene:** never delete `WatchtowerDesktop/.build`; a cold rebuild of the ML dependencies costs minutes (measured 4:24 cold on a loaded machine) plus ~5 GB of disk per worktree. Don't alternate `-c debug`/`-c release` builds in one worktree without need.

**Agent-driven runs (subagent-driven development, fan-out reviews, backlog sweeps).** These rules override a generic skill's defaults in this repo — e.g. an implementer prompt's "run the full suite before committing" means the task-scope checks below, not `go test ./...`. Measured on two 2026-09-26 SDD runs: ~80% of subagent wall-clock was model turns (200–500 per task), the full Go suite ran up to 3× inside one task at ~2 min each, and the machine was swap-thrashing under parallel sessions.
- **Task scope vs phase scope.** An implementer or fix-round subagent runs only the inner loop above for what it touched (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`). The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once per plan phase by the controller and once before the PR — never per task, never per edit. A task that changes a cross-package contract (a shared type, a migration, `buildToolRegistry`) names the extra packages it must run in its brief.
- **Review checklist up front.** The implementer brief carries the same checklist the task reviewer gets (the run's reviewer-common file, or `docs/review/review-rules.md` §§ relevant to the task) and the implementer self-reviews against it before hand-back. The independent review still runs; this only moves findings earlier so fewer tasks need a fix round.
- **No polling turns.** A subagent never spends turns on `sleep N`, `jobs; echo tick`, `:` or repeated `tail` of a log: run the command to a log file with an explicit exit code (`cmd > log 2>&1; echo "exit=$?"`), or run it in the background and wait for its completion notification.
- **Bounded expensive checks.** Fuzzing (`-fuzztime`), mutation checks and `-race` over big packages are welcome but bounded and run once per task at the end, not after each edit. `go test -race ./cmd` stays targeted (`-run`), per the CI note.
- **Tests that spawn processes reap them.** A test starting a subprocess (a fake `claude`/`codex` stub, a helper binary) kills its whole process group and waits for it in `t.Cleanup`, including on the timeout/cancel path it is testing — an orphaned stub reparented to PID 1 survives the test run and keeps loading the machine (seen 2026-09-26: stubs from stuck-write cancellation tests alive for 2 h).
- **Tests that create git repositories keep git's background maintenance out.** The package's `TestMain` calls `gittest.DisableBackgroundGit()` (`internal/gittest`) before `m.Run`; otherwise a detached `git maintenance`/`gc --auto` can still be writing into a `t.TempDir` repository when its cleanup runs ("directory not empty").
- **Parallel lanes only when the plan says so.** Plans list each task's dependencies (`Depends on: Task N` or `none`). Independent tasks may run in parallel lanes, each in its own worktree/branch that the controller merges — never two implementers in one working tree. Swift tasks may run in parallel lanes too — the dev machine has the headroom.

## Database & Migrations

Schema changes use **goose** migrations — numbered SQL files in `internal/db/migrations/` (`0000N_<name>.sql`, each with `-- +goose Up` / `-- +goose Down`), auto-discovered via `//go:embed` and applied on `db.Open` — under a cross-process flock on `<db>.migrate.lock` when any is pending (a waiter past 2 min gets the retryable `db.ErrMigrationInProgress`; a current file takes no lock). There is **no** hand-edited "schema version" int and PRAGMA `user_version` is legacy (Swift uses it only as a floor check). `CurrentSchemaFormat` in `internal/db/migrations.go` is the migration-engine version, not your schema version — do not bump it for ordinary changes.

**One Go migration, as an exception:** version 125 lives in `internal/db/migration_00125.go` (registered with goose, no `00125_*.sql` file — adding one panics with goose's "duplicate version"). It exists only as a tolerant repair (#667: adds its columns only when absent, so files where a branch build applied them under 124 still open). New migrations stay SQL; a Go migration is kept only for such a repair, and must declare the tables it touches in `goMigrationTouches` so the schema-drift check (`loadMigrations`) sees it.

When adding a table/column/CHECK, also mirror it into `internal/db/schema.sql` (embedded and injected into the AI prompt), add new tables to `TestAllTablesExist`, and regenerate the snapshot and the generated Swift test schema `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`). SQLite has no `ALTER TABLE ... ADD CONSTRAINT`, so expanding an enum CHECK (`feedback.entity_type`, `targets.source_type`, `inbox_items.trigger_type`) requires the table-recreation dance — follow the `add-migration` skill and `internal/db/migrations/00150_builtin_automations.sql` (not `00002`/`00003`, whose foreign-key handling is wrong). **A rebuild runs as one transaction:** `-- +goose NO TRANSACTION`, `PRAGMA foreign_keys = OFF;` (outside any transaction), then the whole create-new/copy/drop/rename/indexes sequence as `BEGIN IMMEDIATE; … COMMIT;` inside one `-- +goose StatementBegin` … `-- +goose StatementEnd` block, then `PRAGMA foreign_keys = ON;`. A failure part-way then leaves the tables as they were; separate `BEGIN`/`COMMIT` statements do not work — the driver drops a connection left inside a transaction between execs (`internal/sqlcipher/wt_session.go`), which rolls it back.

**Transactions start `BEGIN IMMEDIATE`** (`db.Open` sets the driver's `_txlock=immediate`): a write transaction takes the write lock up front and waits for it under `busy_timeout`, instead of failing mid-transaction with `SQLITE_BUSY_SNAPSHOT` (517) when another process commits between its first read and first write (WAL never applies `busy_timeout` to that upgrade). A transaction that only reads should use `BeginTx(ctx, &sql.TxOptions{ReadOnly: true})` (stays deferred, never blocks a writer) — on a `query_only` handle (`SetReadOnly`, dev-mode MCP) plain `Begin()` is refused outright. The trade-off: a write transaction now holds the write lock from its first statement, so keep slow reads and renders out of it (render first, then open the tx for the writes only).

**Write transactions are measured** (`internal/db/lockmetrics` in every Go process, `DBLockMetrics.swift` on the Desktop writer): a write transaction (or a Go autocommit write) that waits for or holds the write lock 200 ms or more, and every `SQLITE_BUSY`, lands in `<workspace>/dblock.jsonl` with its call site; `watchtower db lockstats` summarises it. Hooks fail after 1 s or 500 ms of waiting, so keep write transactions short — no network, LLM calls or slow renders inside one. See [docs/features/db-lock-metrics.md](docs/features/db-lock-metrics.md).

The repeatable dev flows (migration, new AI prompt, new pipeline end-to-end, new Desktop tab) are documented as project skills in `.claude/skills/` (`add-migration`, `add-ai-prompt`, `add-pipeline`, `add-desktop-feature`). Use them; they encode the load-bearing steps and gotchas.

---

## Public repo hygiene

This repository is public. Never copy live-install data into it — tests, fixtures, docs, plans, audits and reports alike: no real Slack/Google/Jira ids, corp mail domains or workspace/company names, personal or colleague emails and names, usage stats read off a live database, or local absolute paths. Use placeholders (`<corp-workspace>`, `<corp-domain>`, `<owner-slack-id>`, "colleague A") and neutral samples (`acme`, `example.com`); an agent auditing the owner's live install redacts before writing anything into the repo. Run `make hooks` once per clone: the pre-push hook runs `scripts/leak-check.sh` over the commits being pushed (a private denylist at `~/.config/watchtower/leak-denylist`, plus generic patterns for Slack ids and non-allowlisted email domains); CI's "Leak Check" job runs the same scan over every PR. A deliberate fake that trips a generic pattern carries `leak-check:allow` on its line; a denylist hit has no override. The scan covers each pushed commit's added lines (a merge's conflict-resolution lines included), its message, and its author/committer identity. Known limits: binary files and file paths are not scanned, a generic `/Users/<user>/…` path is not flagged, and a branch that predates the hook has no `scripts/git-hooks/pre-push`, so pushing it runs no check.

---

## Behavior Inventory

Behavioral contracts that must not be modified without explicit owner approval are catalogued in `docs/inventory/`. Before touching code in any module covered by inventory, read the corresponding file and treat each entry as load-bearing.

Module → file mapping is in [docs/inventory/README.md](docs/inventory/README.md).

If a proposed change would weaken or break a guard test, **stop and ask the owner** before proceeding. Do not "improve" a guard test by relaxing its assertions, renaming it out of the `Test<Module>NN_` convention, or splitting it into multiple weaker tests.

House conventions for Desktop code (Swift lifecycle/state patterns, Go↔Swift dual-path contracts, error handling, test expectations) are in the "Swift / Desktop conventions" section of [docs/review/review-rules.md](docs/review/review-rules.md) — read it before writing or reviewing anything under `WatchtowerDesktop/`. Rules there are promoted from recurring `docs/review/review-lessons.md` findings; the lessons file itself is the judge's calibration log, not required reading for feature work.

New Desktop screens are built from the design kit in `WatchtowerDesktop/Sources/DesignKit/` (`make design-gallery` opens every component in its own window, never inside the app); read [docs/design/desktop-style-guide.md](docs/design/desktop-style-guide.md) first (lint-enforced rules, and `make desktop-shots DESKTOP_SHOTS=<dir>` to look at your screen before review).
