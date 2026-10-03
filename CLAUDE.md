# Watchtower — Developer Notes

**Project:** `watchtower` (Go module: `watchtower`)
**Backend:** Go 1.25, SQLite via `modernc.org/sqlite` (`database/sql`), see `go.mod`
**Desktop:** SwiftUI macOS app (Swift 5.10 language mode, macOS 14+; building requires a Swift 6+ toolchain / Xcode 16+ — the FluidAudio dependency's manifest declares swift-tools 6.0), GRDB.swift, see `WatchtowerDesktop/Package.swift`

---

## Feature Notes

Detailed per-feature notes — architecture, contracts, dual paths, v1 limits — live in docs/features/; read the relevant file before touching that area.

- [Onboarding v2 — Goals → Connect → About you (2026-10-03, replaces the eight-step onboarding)](docs/features/onboarding-v2.md) — `OnboardingStateMachineV2` + legacy step migration, goal → feature mapping, sidebar visibility + "+ Connect…" row, OWNER-01 `OnboardingProfileWriter`, `workspace init` / `sync --users-only`, the single daemon start at finish, Run setup again, late About you and the related-features offer; walkthrough in `docs/onboarding-flow.md`.
- [Attention detection — the inbox feeder (2026-09-14, replaces the Assistant Inbox + Dashboard)](docs/features/attention-detection.md) — `internal/inbox/` mechanical detector pipeline feeding Catch-Up, briefing and meeting prep; INBOX-02/05/09; what the 2026-09-14 demolition retired.
- [Knowledge search (2026-09-26)](docs/features/knowledge-search.md) — `internal/kb/` FTS5 index, `phaseKnowledgeIndex` cursors, `search_knowledge` ranking and link rules; KB-01..03.
- [Confluence knowledge connector (2026-09-26)](docs/features/confluence-knowledge-connector.md) — `ext_*` raw store, `internal/extsync` engine, `internal/confluence`, `internal/extract` helpers, `doclinks`/`linkscan`; EXT-01..04.
- [Confluence page editing from the chat (2026-09-30)](docs/features/confluence-page-editing.md) — `get_confluence_page`/`edit_confluence_page`, `internal/confluenceedit` block model, merge rulings R4–R14, version pinning; EXT-05.
- [Embedded assistant chats — shared component (2026-10-01)](docs/features/embedded-chat.md) — `EmbeddedChatEngine`/`ChatSurfaceSpec`/`EmbeddedChatCenter` in WatchtowerCore, `ChatFeedView`/`ChatComposerBar` shared with the main chat, 3-turn gate, explicit `toolAccess`; #168.
- [Chat Redesign (2026-09-26)](docs/features/chat-redesign.md) — Warm `ai session` protocol v2, Go-owned system prompt, migration 00076 chat tables, `ChatSessionPool`, attachments/artifacts; CHAT-01..05.
- [Slack send from the chat and the workbench terminal (2026-10-02)](docs/features/slack-send.md) — `send_slack_message` + `get_writing_style`, propose-time recipient pinning and workspace candidates, `Registry.Approve` with owner edits, `chat:write` re-consent, propose-only under DirectApply (DEV-06 amended).
- [Workbench — Claude Code works a folder-bound board (2026-09-29, POC; renamed from Projects 2026-10-02)](docs/features/workbench.md) — Folder-bound boards, `watchtower mcp --workbench` (legacy `--project` aliases), embedded terminal, target comments, owner asks replacing the Documents pane (2026-10-03: `owner_asks`, `ask_owner`/`get_ask`/`list_asks`/`withdraw_ask`, the Waiting-for-you stack and drawer, typed-never-submitted delivery + brief fallback, ask guard Stop prompt + `AskUserQuestion` block, PROJ-12/13), status rollup and history, board drift check, the folder's text files in search (git-listed, own sessions only), re-parenting targets, code viewer (FILES tree, Files pane with Monaco tabs, autosave, git marks), git branch header (`workbench git …`, PROJ-10), session agent state from async Claude Code hooks + macOS notice (`workbench session-state`, `SessionAgentStateCenter`, PROJ-11), session report and states (2026-10-03: migration 00101, `finish_session`, session target links, `internal/sessionreport` + `workbench session-report`, PR cache, Stopped/Finished/Error states via `SessionStatePresentation`, ask guard prompt v2, pack v3, PROJ-11/13 amended, PROJ-14); PROJ-01..09 (ids kept), DEV-06.
- [Code navigation in the workbench code viewer (2026-10-02, phases A–B)](docs/features/code-navigation.md) — `watchtower code index|search` (`internal/codeindex`/`codesearch`/`codewalk`, JSON lines, `skipped`/`defs` flags), `CodeIndexCenter`/`OpenQuicklyCenter`/`CodeNavigationCenter`/`CodeUsagesCenter` on `AppState`, `CodeCLIProcess` groups reaped on quit, page messages, Navigate menu gated on the key workbench window; R21–R37, manual-only key routing.
- [Catch-Up — absence recap (2026-09-04)](docs/features/catchup.md) — `internal/catchup/` window, top-up, `catchup.compose` ref validation, acknowledge across five `read_at` surfaces; CATCHUP-01..04.
- [Meeting Transcriber (v74+)](docs/features/meeting-transcriber.md) — Pluggable transcription providers, `MicAGC`, diarization and roles, voice registry, live transcription, warm engine slot, segments, notes, chat.
- [Memory (Phases 0–5 slice 4)](docs/features/memory.md) — `internal/memory/` vault, consolidation and semantic tier, surfaces, sources, render-inversion, mirrors, step memo; MEM-01..15.
- [Google Multi-Account (sub-project 1 of 3 of the multi-account initiative, 2026-07-30)](docs/features/google-multi-account.md) — `google_accounts`, per-account token files, `wireGoogleSyncers` fan-out, Gmail inbox/memory scoping.
- [Slack Multi-Account (sub-project 2 of 3 of the multi-account initiative, 2026-07-31)](docs/features/slack-multi-account.md) — `slack_accounts`, namespaced `<acct>:<id>` strings, per-account sync and inbox detection, identity-scoping decisions, `active_workspace` resolution.
- [Jira Multi-Account (sub-project 3 of 3 of the multi-account initiative, 2026-08-02)](docs/features/jira-multi-account.md) — `jira_accounts` composite PKs, per-account syncers, `ErrAuthRevoked` status writers, non-destructive remove.
- [Jira status history + time in status (2026-10-02)](docs/features/jira-changelog.md) — `jira_issue_changelog`/`jira_changelog_sync`/`jira_linked_issues` (00095), `Syncer.syncHistory` bulk changelog + linked-issue fetch, `get_jira_status_history`/`get_jira_time_in_status` read tools.
- [Model & Provider Registry (2026-08-18)](docs/features/model-provider-registry.md) — `internal/providers` registry, per-tier model resolution, `digest.TierForSource`, tier property scan, `ai models`.
- [Menu-Bar Tray + Daemon Lifecycle + CLI Binary Store (2026-08-07)](docs/features/tray-daemon-lifecycle.md) — Menu-bar tray, activation policy, `CLIBinaryStore`, `sync --now`, sync heartbeat, Slack HTTP timeouts and API budget, `sync stop --force`.
- [Ideas & Decisions Registry (2026-08-07)](docs/features/ideas-decisions-registry.md) — `internal/ideas/` two-stage mining, floors, backfill, Desktop Ideas tab, decisions split; IDEA-01..05.
- [Developer Surface — MCP tools + skill pack (2026-08-09)](docs/features/developer-surface.md) — `get_task_context`/`find_experts` read tools, embedded skill pack, `integrate claude-code`; DEV-01..05.
- [Feature Manager (2026-08-16)](docs/features/feature-manager.md) — `internal/features/` registry, per-phase gates, fast-forward hooks, `features` CLI, onboarding splash; FEAT-01..04.
- [Voice Dictation (2026-08-11)](docs/features/voice-dictation.md) — `DictationCenter`, shared engine slot handshake, `MicRecorder`, `dictate clean`, Carbon hotkey, Quick Capture.
- [Target Brief Chat (2026-08-19)](docs/features/target-brief-chat.md) — Composer-based target creation, `TargetBriefCenter`, propose/execute action modes; TGT-BRIEF-01..03.
- [Persona Merge — one assistant (2026-08-19)](docs/features/persona-merge.md) — One assistant replacing two personas; per-surface capability contracts, persona-agnostic skills, stable legacy identifiers.
- [Agent Actions — tool registry + controlled writes (2026-09-04)](docs/features/agent-actions.md) — `internal/tools/` registry, `agent_actions` propose/apply-exactly-once, trust, `buildToolRegistry`; AGENT-01..06.
- [Quick Connections — owner-managed external MCP servers (2026-09-09)](docs/features/quick-connections.md) — `external_connections`, secret files, MCP config merge, `internal/mcpoauth` sign-in and refresh; QC-01..04.
- [Reaction Commands + Inbox Action Strip (Wave 1 2026-09-05, Wave 2 2026-09-06)](docs/features/reaction-commands.md) — `internal/reactioncmd/` ledger and dispatch, Wave 2 tools, reminders, inbox action strip; REACT/STRIP/REMIND contracts.
- [Strong-tier cost fixes — daemon cadence gates + attempt budgets (2026-09-13)](docs/features/strong-tier-cost-fixes.md) — Daily rollup gate, day plan/briefing and next-step attempt budgets, memory step memo pointer.
- [Audit fix wave 5 (2026-09-14)](docs/features/audit-fix-wave-5.md) — Reaction-commands seeding and default-on, prompt-store wiring, daemon log stream, rollup budget, recap attribution, calendar guard, chat argv.
- [Owner identity (2026-09-25, decision 15 of the 2026-09-13 feature audit)](docs/features/owner-identity.md) — `db.ResolveOwner` ladder, singleton profile, no-silent-skip errors, Swift `OwnerQueries` twin; OWNER-01..02.

---

## Build & Test

**Inner loop (while iterating — this is the default, full runs are NOT):**
- Go: test only the touched package — `go test ./internal/<pkg>` (add `-run TestName` to narrow further). The Go build/test cache makes this seconds; never add `-count=1` reflexively, it defeats the cache.
- Swift: always filter — `make test-swift FILTER=<TestClass>` (a regex alternation such as `FILTER='ClassA|ClassB'` works too — the recipe quotes it) (or `cd WatchtowerDesktop && swift test --filter <TestClass>`). An unfiltered `swift test` re-links the whole ML stack and belongs to the gate only. Core-level code lives in `WatchtowerCore` and its tests in `Tests/Core`, which build without the ML stack — prefer testing there when touching Models/Database/pure Services (measured ~0:12 edit→test vs the ~0:35 pre-split baseline; see `docs/superpowers/specs/2026-08-11-local-build-speed-design.md`'s Phase 2 appendix — the shared test bundle still links ML at run time, so the win is in compile time, not in avoiding the link).
- Lint: `make lint-diff` (issues introduced vs origin/main). Full `make lint` is the gate.

**Gate (before a PR):** full `make test`, `make test-swift`, `make lint-all`.

**Cache hygiene:** never delete `WatchtowerDesktop/.build`; a cold rebuild of the ML dependencies costs minutes (measured 4:24 cold on a loaded machine) plus ~5 GB of disk per worktree. Don't alternate `-c debug`/`-c release` builds in one worktree without need. Before a heavy build on a loaded machine, `bash scripts/dev-health.sh` shows the known killers (swap, leaked containers, stale sessions).

**Agent-driven runs (subagent-driven development, fan-out reviews, backlog sweeps).** These rules override a generic skill's defaults in this repo — e.g. an implementer prompt's "run the full suite before committing" means the task-scope checks below, not `go test ./...`. Measured on two 2026-09-26 SDD runs: ~80% of subagent wall-clock was model turns (200–500 per task), the full Go suite ran up to 3× inside one task at ~2 min each, and the machine was swap-thrashing under parallel sessions.
- **Task scope vs phase scope.** An implementer or fix-round subagent runs only the inner loop above for what it touched (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`). The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once per plan phase by the controller and once before the PR — never per task, never per edit. A task that changes a cross-package contract (a shared type, a migration, `buildToolRegistry`) names the extra packages it must run in its brief.
- **Review checklist up front.** The implementer brief carries the same checklist the task reviewer gets (the run's reviewer-common file, or `docs/review/review-rules.md` §§ relevant to the task) and the implementer self-reviews against it before hand-back. The independent review still runs; this only moves findings earlier so fewer tasks need a fix round.
- **No polling turns.** A subagent never spends turns on `sleep N`, `jobs; echo tick`, `:` or repeated `tail` of a log: run the command to a log file with an explicit exit code (`cmd > log 2>&1; echo "exit=$?"`), or run it in the background and wait for its completion notification.
- **Bounded expensive checks.** Fuzzing (`-fuzztime`), mutation checks and `-race` over big packages are welcome but bounded and run once per task at the end, not after each edit. `go test -race ./cmd` stays targeted (`-run`), per the CI note.
- **Tests that spawn processes reap them.** A test starting a subprocess (a fake `claude`/`codex` stub, a helper binary) kills its whole process group and waits for it in `t.Cleanup`, including on the timeout/cancel path it is testing — an orphaned stub reparented to PID 1 survives the test run and keeps loading the machine (seen 2026-09-26: stubs from stuck-write cancellation tests alive for 2 h).
- **Parallel lanes only when the plan says so.** Plans list each task's dependencies (`Depends on: Task N` or `none`). Independent tasks may run in parallel lanes, each in its own worktree/branch that the controller merges — never two implementers in one working tree. Heavy Swift work stays one lane at a time: two concurrent ML-stack links on a 16 GB machine cost more than they save.
- **Load check before and during long runs.** The controller runs `bash scripts/dev-health.sh` before dispatching a phase. If its last line is `HEALTH: overloaded` (load above 3× cores or free memory below 15%), stop dispatching and tell the owner what is holding the machine (it lists the suspects); do not kill another session's processes or containers without the owner's go-ahead.

## Database & Migrations

Schema changes use **goose** migrations — numbered SQL files in `internal/db/migrations/` (`0000N_<name>.sql`, each with `-- +goose Up` / `-- +goose Down`), auto-discovered via `//go:embed` and applied on `db.Open`. There is **no** hand-edited "schema version" int and PRAGMA `user_version` is legacy (Swift uses it only as a floor check). `CurrentSchemaFormat` in `internal/db/migrations.go` is the migration-engine version, not your schema version — do not bump it for ordinary changes.

When adding a table/column/CHECK, also mirror it into `internal/db/schema.sql` (embedded and injected into the AI prompt), add new tables to `TestAllTablesExist`, and regenerate the snapshot and the generated Swift test schema `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`). SQLite has no `ALTER TABLE ... ADD CONSTRAINT`, so expanding an enum CHECK (`feedback.entity_type`, `targets.source_type`, `inbox_items.trigger_type`) requires the table-recreation dance — see `internal/db/migrations/00002`/`00003`.

**Transactions start `BEGIN IMMEDIATE`** (`db.Open` sets the driver's `_txlock=immediate`): a write transaction takes the write lock up front and waits for it under `busy_timeout`, instead of failing mid-transaction with `SQLITE_BUSY_SNAPSHOT` (517) when another process commits between its first read and first write (WAL never applies `busy_timeout` to that upgrade). A transaction that only reads should use `BeginTx(ctx, &sql.TxOptions{ReadOnly: true})` (stays deferred, never blocks a writer) — on a `query_only` handle (`SetReadOnly`, dev-mode MCP) plain `Begin()` is refused outright. The trade-off: a write transaction now holds the write lock from its first statement, so keep slow reads and renders out of it (render first, then open the tx for the writes only).

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
