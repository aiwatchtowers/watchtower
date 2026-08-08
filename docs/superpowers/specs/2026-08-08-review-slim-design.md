# Review pipeline slimming — drop the debate, lean on codex

**Date:** 2026-08-08
**Status:** approved by owner (chat, 2026-08-08)

## Problem

A month of Claude Code session analysis (2026-07-08 → 2026-08-08) showed the review
pipelines drive roughly half of all token usage: ~6.7B cache-read tokens, 635 subagent
dispatches, ~21 session-limit hits pausing autonomous runs for hours. The lessons log
(`docs/review/review-lessons.md`, 45 blocks) gives a per-lane value signal:

- Unique catches ("miss" mentions): codex 16, prosecutor 9, silent-failure-hunter 5,
  pr-test-analyzer 5, advocate 4, code-reviewer 2, code-simplifier 1.
- All 45 `outcome:` lines are TBD — the learning loop never closed once, yet the
  498-line lessons file was fed to every agent of every run (~10 agents/run).
- The advocate's function (dismissing weak prosecutor findings) duplicates the judge's
  dedup/dismissal pass — 31 false-positives were dismissed by the judge over the period.

## Decision

### debate-review becomes a slim panel + judge (no debate)

The skill keeps its name and triggers; the internals change:

- **One parallel batch:** prosecutor (session model) + codex (via codex-wrapper, sonnet)
  + three `pr-review-toolkit` specialists on sonnet (`pr-test-analyzer`,
  `silent-failure-hunter`, `code-reviewer`). Then the **judge** (session model).
- **Removed:** the advocate persona (`.claude/agents/review-advocate.md` deleted), the
  rebuttal round (Step 2), the debate ledger, the `rounds` and `fast` inputs (the skill
  now IS the old fast mode minus the advocate), and the `code-simplifier` lane
  (1 unique catch; overlaps the prosecutor on simplicity).
- Cost: 10 agent calls (5 on the session model) → 6 calls (2 on the session model).

### Verification mode (`verify`)

For convergence rounds after fixes, `debate-review verify` dispatches **codex + judge
only**, pointed at the post-fix diff plus the list of findings fixed last round. The
prosecutor does not re-run; codex is the verification lens (it is independent of Claude
session limits and was the top unique-catcher). If codex is unavailable on a verify
round, the prosecutor substitutes — a verify round never runs on zero reviewers.

### Lessons log becomes judge-only

- Only the **judge** reads `docs/review/review-lessons.md`, and only the **last 10
  blocks**. The prosecutor and specialists read the diff + `review-rules.md` only.
- The reflection append, `--outcome` mode, and operator-gated promotion stay unchanged
  (they cost nothing per run; the owner may still close the loop later).

### local-review integration (codex-first repeat rounds)

- **Final PR:** round 1 → full `debate-review`; rounds 2+ → `debate-review verify`.
- **Per-branch:** round 1 → the four-voice panel (unchanged); rounds 2+ → **codex
  alone** as the verification reviewer, with `pr-review-toolkit:code-reviewer` as the
  fallback when codex is unavailable. (Previously rounds 2+ ran both.)

## Rationale for leaning on codex

codex runs on a separate billing/limit pool — it consumes no Claude tokens and cannot
trigger a session-limit pause — and it produced the most unique catches over the period.
It stays best-effort (it can hang or time out) and never becomes a hard gate; round-1
discovery keeps the Claude lenses because codex alone missed what the prosecutor and
specialists caught.

## Out of scope

- Renaming the skill (triggers and muscle memory keep `debate-review`).
- Any change to `docs/review/review-rules.md` semantics or the promotion flow.
- Per-branch round-1 panel composition (already tuned in this branch).
