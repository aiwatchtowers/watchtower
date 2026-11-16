# Watchman — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/watchman/`, `internal/db/watchman*.go`,
> `internal/daemon/watchman.go` or `cmd/watchman*.go`, read this file first. Any
> proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/watchman/` + `internal/db/watchman.go` + `internal/db/watchman_learn.go` + `internal/db/watchman_profile.go` + `internal/db/watchman_keys.go` + `internal/db/migrations/00194_watchman.sql` + `00195_watchman_skipped_keys.sql` + `internal/daemon/watchman.go` + `cmd/watchman*.go`
**Last full audit:** 2026-11-16 (created, phase 1)
**Owner approval:** spec `docs/superpowers/specs/2026-11-16-watchman-design.md` (ask #1385); feature note `docs/features/watchman.md`.

WATCHMAN-01, -02, -04 and -05 of the spec arrive with phase 2; this file holds the two contracts phase 1 sets.

---

## WATCHMAN-03 — twin decisions become precedents only after the owner's OK

**Status:** Enforced (Go).

**Observable:** Watchman learns from one closed list of sources, `DBSources()` + `TurnSource` + `GitSource` (`ask`, `review`, `spec`, `permission`, `turn`, `git`), each reading only decisions the owner made himself, in a workbench: answered asks (not an automation's, not dismissed), his diff-review and spec-review marks, permission prompts he allowed or denied, his own lines in agent sessions and his own commits and merges. No source reads a decision a twin took. Phase 2 adds the OK'd-journal source under this same id, so a twin decision becomes a precedent only after the owner confirms it.

**Why locked:** A twin that learns from its own unconfirmed decisions drifts away from the owner and then grades itself on its own answers; every precedent must trace to something the owner actually did or confirmed.

**Test guards:**
- `internal/watchman/guard_test.go::TestWATCHMAN03_SourcesAreOwnerOnly` (the source names are the closed list; automation, open and dismissed asks and pending, expired and answered-on-Mac permissions are not read)
- `internal/watchman/source_asks_test.go::TestAsksSource_SkipsAutomationAndOpen`, `internal/watchman/source_permission_test.go::TestPermissionSource_SkipsPendingExpiredAndAnsweredOnMac`, `internal/watchman/source_git_test.go::TestGitSource_SkipsAgentCommits`

## WATCHMAN-06 — learning and the backtest never act

**Status:** Enforced (Go).

**Observable:** Phase 1 reads, labels, profiles and measures; it answers no ask, decides no permission, writes no review, merges nothing and types into no session. `internal/watchman` imports none of `internal/hub`, `internal/sessionhost` and `internal/tools`. Phase 2's acting code lives in its own package, so this contract stays true for learning and the backtest. `Decide` never writes, and `watchman learn --start` and `watchman backtest` are the owner's verbs, refused under an AI agent's environment markers (AGENT-07).

**Why locked:** Phase 1 is the measurement that decides whether the twin may act at all (the go/stop verdict); code that could act inside the learning package would let a measurement change what it measures.

**Test guards:**
- `internal/watchman/guard_test.go::TestWATCHMAN06_NoActingImports` (no non-test file of the package imports the three packages or their subpackages)

**Locked since:** 2026-11-16

---

## Changelog

- 2026-11-16 (phase 1, board #1823): file created with WATCHMAN-03 and WATCHMAN-06 (new, beyond the spec's five).
