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

## Swift / Desktop conventions

Promoted 2026-08-04 from recurring `review-lessons.md` findings (source dates cited per rule;
the matching lesson entries are marked `[promoted]`). These bind authors as well as reviewers —
read this section before writing or reviewing anything under `WatchtowerDesktop/`. Dimension
tags in brackets.

### Lifecycle & state

- State for an async operation that must survive navigation lives in `AppState` or an app-wide center (`MeetingRecorderCenter`, `TranscriptNotesCenter`), never in a view-local ViewModel; the test must exercise start → navigate away → return. (memory) [1/6]
- A ViewModel backing an always-visible surface (sidebar badge, indicator) must be constructed on EVERY path that reveals that surface — e.g. both `!needsOnboarding` and `completeOnboarding()`. (2026-06-16) [6]
- When a view gains the ability to mutate data that a lazily-created sibling ViewModel snapshotted at init, every mutation site must invalidate or recreate that VM — newly-mutable state plus a `let`-snapshot consumer is the auto-flag. (2026-07-13 CX-1, recurred 2026-07-31) [6]
- Any new view in the recording file-family that loads recordings/recaps on appear must also reload on `meetingRecorderCenter.phase → .idle`; conversely, a change to the `phase` projection must prove `.idle` stays reachable from every terminal state. (2026-07-31, 2026-08-03) [6/8]
- An automatically-invoked action riding a user gesture (e.g. auto-record on Join) must inherit every capability/availability gate its manual twin enforces; a `.disabled(...)` condition on the manual control with no matching guard on the automatic path is the tell. (2026-07-31 meet-join) [6/9]

### Go ↔ Swift dual-path contracts

- A Go-side write guard, status/ack cascade, or collision guard on a table also written by a Swift `*Queries` twin must land with its mirror in the same change (or document divergent semantics and ship the collision test); the existing twin guard is the auto-flag. (2026-07-04 R2-F13, 2026-07-13 F1) [8]
- Wire shape: a nil Go slice marshals to JSON `null` and a non-optional Swift `[T]` then throws on decode; initialise slices to `[]T{}` (or omitempty + Swift optional/default) and add a test asserting the empty-state wire shape. (2026-06-16, recurred verbatim 2026-07-04) [8/9]
- A string datetime column read by both Go and Swift pins an explicit timezone in BOTH formatters; a sibling formatter that sets UTC while the used one doesn't is the tell. (2026-07-04) [6/8]
- Envelope symmetry: each NEW best-effort payload in a CLI command gets its own `*_ok`/`*_error` envelope fields (the `recap_ok` precedent) AND a Swift decoder field consuming them, in the same change; a degradation warning must survive the caller's exit-0 path — `ProcessCLIRunner` discards stderr on success. (2026-07-31 ×3) [8/9]
- A Swift ViewModel that hardcodes a CLI flag (e.g. `--app-return`) requires verifying the flag is registered on EVERY cobra subcommand that reaches that flow — mechanically greppable; cobra rejects unknown flags before RunE runs. (2026-08-03) [6]

### Error handling

- Desktop mark-read/ack must not clear UI state before the DB write succeeds: do/catch and clear only on success (the DigestViewModel pattern), never `try?` plus an unconditional clear. (2026-06-16) [9]
- A ViewModel read-modify-write of a whole JSON column must reload the row immediately before writing (the TargetChatViewModel pattern). (2026-07-04) [9]
- A scan/validation site where "file missing" is a meaningful contract state must treat "file present but undecodable" as a THIRD state, never fold it into the missing branch; a `compactMap` over two chained `try?` where only one of them means "absent" is the tell. (2026-08-03, 5th recurrence of the absent-vs-error class) [9]

### Tests

- Every new `@Observable` ViewModel/center ships with its own test suite in the same change — the recurring failure shape is bimodal coverage: a thorough library-layer suite beside a zero-test VM or CLI entry point, where green-overall masks the untested core. (weak-dimension 7 in ≥5 consecutive lesson entries) [7]

🤖 Generated with [Claude Code](https://claude.com/claude-code)
