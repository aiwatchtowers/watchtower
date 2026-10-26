# Agent coach — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/coach/`, `internal/db/coach.go`,
> `internal/prompts/additions.go`, `internal/daemon/coach.go` or `cmd/coach.go`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/coach/` + `internal/db/coach.go` + `internal/db/coach_signals.go` + `internal/prompts/additions.go` + `internal/daemon/coach.go` + `cmd/coach.go`
**Last full audit:** 2026-10-26 (created)
**Owner approval:** spec `docs/superpowers/specs/2026-10-26-agent-coach-design.md` (D3 asks #637, D6 #648); feature note `docs/features/agent-coach.md`.

---

## COACH-01 — nothing is applied without the owner's Accept, and never a repository file

**Status:** Enforced (Go).

**Observable:** The weekly pass and `coach run` only store proposals (`coach_proposals`, status `open`); every destination — the owner's session, procedure and chat texts, a prompt's additions, `~/.claude/settings.json`, `~/.claude/CLAUDE.md` — is unchanged until `Applier.Accept` (the owner's `coach accept`) writes that one proposal. `coach accept`, `decline`, `rollback` and `run` are refused under an AI agent's environment markers (AGENT-07). The destination set is the owner's own setup: a repository file (the repo `CLAUDE.md`, `.watchtower/*`, `.claude/skills/`, a project `.claude/settings.json`) is never a destination, and the two files under the home folder are `<home>/.claude/settings.json` and `<home>/.claude/CLAUDE.md`. A model-proposed destination outside the set is dropped by `Validate`.

**Why locked:** The coach turns an agent-visible signal into edits of the text every agent reads next. An edit applied on its own, or into a file a team shares, is a prompt injection path and a surprise for the owner (spec D3, D6).

**Test guards:**
- `internal/coach/coach01_test.go::TestCOACH01_NothingAppliedWithoutAccept` (a validated proposal stored by `Proposer.Run` leaves the three texts, the additions and both home files byte-identical; Accept changes only its own destination)
- `internal/coach/coach01_test.go::TestCOACH01_DestinationsAreNeverRepoFiles` (the destination set is pinned; repo-file destinations are dropped)
- `cmd/coach_test.go::TestCoachAccept_RefusedUnderAgent` (accept, decline, rollback and run refuse under a marker, the proposal stays open)

**Locked since:** 2026-10-26

---

## Changelog

- 2026-10-26 (agent coach Plan 1, board #1120): file created with COACH-01. Related amendments: SPECREVIEW (`not_useful` mark, `findings`) in `spec-review.md`, AGENT-07 in `agent-actions.md`.
