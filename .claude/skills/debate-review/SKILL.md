---
name: debate-review
description: Use when the user wants a deep or adversarial review of a diff or PR, says "debate review", "advocate vs prosecutor", "tear this PR apart", or wants a second opinion beyond /code-review. Adversarial multi-agent code review for the Watchtower repo (Go CLI + SwiftUI Desktop), judged against the project ruleset in docs/review/review-rules.md.
---

# Debate Review

Adversarial code review: a Claude advocate defends the change, a Claude prosecutor attacks it, they debate under a capped round limit, an independent codex review runs in parallel, the `pr-review-toolkit` specialist panel (`pr-test-analyzer`, `silent-failure-hunter`, `code-simplifier`, `pr-review-toolkit:code-reviewer`) also runs in parallel, and a judge synthesises the final verdict from all of them. You are a thin orchestrator — all agents (advocate, prosecutor, codex, the four specialists, judge) are read-only: they inspect the diff and repo but never edit files or run git/network mutations.

## Inputs

- **Review target**: current branch diffed against a base (default `main`), or a PR via `gh pr diff <PR#>`. Specify with `--base <branch>` or `--pr <PR#>`.
- **rounds**: number of debate rounds (default `2`). Minimum `1`.
- **fast**: flag that collapses to round 1 + judge only (no rebuttal). Cheaper and shallower.
- **comment**: flag to post findings as inline PR comments after printing the report (default off — print only).
- **outcome mode**: `--outcome <PR#>` — instead of running a review, record the real-review result of a past run into the lessons log (see Outcome feedback). This is the strong self-learning signal.

## Step 0 — load ruleset

Read `docs/review/review-rules.md`. If it is absent, bootstrap it from the nine dimension headers (see `references/agent-prompts.md`) and continue. Graceful-empty: a sparse ruleset is fine — all agents fall back to the dimension definitions in `references/agent-prompts.md` plus project best practices (`CLAUDE.md`, `docs/inventory/`).

Also read `docs/review/review-lessons.md` (bootstrap from its template if absent) — the soft-calibration log of past lessons. Both files are passed to every agent: `review-rules.md` as **binding** rules, `review-lessons.md` as **soft calibration** (observations, not binding).

## Step 1 — round 1 (parallel)

Get the diff:

- Branch mode: `git diff <base>...HEAD`
- PR mode: `gh pr diff <PR#>`

Dispatch in one parallel batch:

1. The **advocate** — `subagent_type: "review-advocate"` (Agent tool).
2. The **prosecutor** — `subagent_type: "review-prosecutor"` (Agent tool).
3. The **codex** run — dispatch the `codex-wrapper` agent (`subagent_type: "codex-wrapper"`); set `BASE_BRANCH` to the same base as the debate.
4. The **`pr-review-toolkit` specialist panel** — four subagents, dispatched in the same batch:
   - `subagent_type: "pr-review-toolkit:pr-test-analyzer"` — behavioural coverage gaps (rated 1–10).
   - `subagent_type: "pr-review-toolkit:silent-failure-hunter"` — swallowed errors, unlogged catches.
   - `subagent_type: "pr-review-toolkit:code-simplifier"` — clarity, redundant abstractions.
   - `subagent_type: "pr-review-toolkit:code-reviewer"` — general quality against the toolkit's ruleset. **Always with the `pr-review-toolkit:` prefix.**

All seven calls are independent and read-only, so the parallel dispatch is safe — no worktree needed.

The `review-advocate` / `review-prosecutor` agents (`.claude/agents/`) already carry their persona, the nine dimensions, and the read-only tool boundary — their system prompts mirror `references/agent-prompts.md`, and the harness enforces read-only (no Edit/Write). So pass each one only the **inputs** for this run: the diff and the path/contents of `docs/review/review-rules.md` (they read `review-lessons.md` themselves). The four specialist agents carry their own personas from the plugin; pass them only the diff.

Collect all seven outputs before proceeding. Codex and each of the four specialists are best-effort: codex is wrapped in `timeout` (see `references/agent-prompts.md`); for each specialist, if it stalls or yields no verdict, proceed with what came back and mark that lane `unavailable` for the judge — never block the debate on a stuck reviewer. The advocate and the prosecutor are not best-effort — if either fails, retry once; if it fails again, escalate (the debate cannot proceed without both sides).

## Step 2 — round 2 (rebuttal)

Build the debate ledger from the prosecutor's round-1 findings (schema in `references/agent-prompts.md`). Relay the ledger to:

1. The **advocate** (`subagent_type: "review-advocate"`) — rebut or concede each prosecutor finding with a concrete reason and rule/code reference.
2. The **prosecutor** (`subagent_type: "review-prosecutor"`) — press (strengthen with evidence) or drop each finding in response to the advocate's defense.

Record each finding's disposition: `agreed-issue`, `dismissed`, or `unresolved`. Repeat until the round cap is reached.

Skip this step entirely when `fast` is set.

## Step 3 — judge

Dispatch the judge as `subagent_type: "review-judge"` with the final debate ledger, the codex findings, the four `pr-review-toolkit` specialist outputs (any that ran), the ruleset, and the nine dimensions as inputs (its persona and report format live in the agent definition, mirroring `references/agent-prompts.md`). The judge ALWAYS runs — even when both debaters agreed — because it provides the independent synthesis that merges the codex findings + specialist findings with the debate outcome. Unlike the other agents it is allowed exactly one write — the Step 4 reflection append to `docs/review/review-lessons.md` — and nothing else.

The judge dedupes across debate / codex / specialist outputs (overlaps are expected — simplicity findings often show up across the prosecutor and `code-simplifier`; coverage gaps from `pr-test-analyzer` often echo what the prosecutor raised). When a finding is raised by multiple lanes, the judge keeps one entry and records "raised by N lanes" — that agreement is signal, not noise.

The judge resolves `unresolved` items where possible. Items it genuinely cannot resolve surface under "Needs human" — never silently dropped.

## Output

Print the judge's report (format defined in `references/agent-prompts.md`): verdict (`approve` / `changes-needed`), blockers, major/minor/nits grouped by severity, "Needs human" items, and a summary paragraph.

If `--comment` was passed, post each finding as an inline PR comment at its `location` — one comment per finding, same as `/code-review --comment`.

## Step 4 — reflect & learn

After the verdict (every run, fast mode included), the judge appends ONE dated block to `docs/review/review-lessons.md` so the system calibrates over time. Capture only what is worth remembering — contested/unresolved points, false-positives (raised then dismissed), misses (caught only by codex / late / by a human), weak dimensions, and rule gaps. Use the reflection entry format in `references/agent-prompts.md`. This is an observation log — the judge never edits `review-rules.md`.

## Outcome feedback (`--outcome <PR#>`)

The strongest learning signal is the real outcome, not the judge's own opinion. In outcome mode the orchestrator does not run a review: it asks the operator which findings actually held up after the real human review / merge, and records them on the matching lesson block's `outcome:` line (format in the reference). Never invent outcomes — record what the operator reports.

## Promotion (gate against learning the wrong thing)

Auto-entries in `review-lessons.md` never become binding rules on their own. When a lesson proves out, the operator promotes it into `docs/review/review-rules.md` under the matching dimension and marks it `[promoted]` in the lessons log. This two-tier split (free auto-log → operator-gated binding rules) keeps the system from reinforcing a wrong lesson.

## Fast mode

`--fast`: run step 1 (round 1 only) then step 3 (judge directly). Skip step 2 entirely. The judge receives the prosecutor's raw findings and the codex output, with no rebuttal ledger. Use when you want a quick second opinion without the full adversarial cycle.

## Anti-patterns

- **Never skip the judge.** Even if advocate and prosecutor reach full agreement, the judge's independent pass (with codex) is mandatory — it is not a rubber-stamp.
- **Never drop `unresolved` findings.** Surface every unresolved item under "Needs human" in the report; do not silently discard them.
- **Never invent findings to "win".** Prosecutor findings must be checkable (file:line, rule reference). Vague or fabricated issues are disqualified.
- **Agents are read-only.** None of the agents in this skill (advocate, prosecutor, codex, the four `pr-review-toolkit` specialists, judge) may edit files, commit, push, or run any mutation. The orchestrator also makes no edits during review.
- **Always dispatch `pr-review-toolkit:code-reviewer` with the namespace prefix.** A bare `subagent_type: "code-reviewer"` is not a Watchtower agent — the toolkit's `code-reviewer` lens then goes silently missing from the judge's inputs.
- **Never exceed the round cap.** After `rounds` iterations, stop debating and move to the judge regardless of unresolved count.
- **Never auto-promote lessons to rules.** `review-lessons.md` is observations only; the operator moves a lesson into `review-rules.md`. In `--outcome` mode never invent outcomes — record what the operator reports.

## References

- `.claude/agents/review-advocate.md`, `review-prosecutor.md`, `review-judge.md` — the three debate personas as first-class subagents (persona + tool boundary). Dispatch them by `subagent_type`; `references/agent-prompts.md` remains the source of truth their prompts mirror.
- `.claude/agents/codex-wrapper.md` — the codex voice (best-effort, wrapped in `timeout`).
- `references/agent-prompts.md` — prompt templates for advocate, prosecutor, and judge; the codex command; the nine dimension definitions; the finding schema, debate ledger schema, and report format.
- `docs/review/review-rules.md` — project-specific binding rules loaded by every agent.
- `docs/review/review-lessons.md` — auto-learning log (Step 4 reflections + outcomes); soft calibration read by every agent; operator-gated promotion into the rules.
