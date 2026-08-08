---
name: debate-review
description: Use when the user wants a deep review of a diff or PR, says "debate review", "tear this PR apart", or wants a second opinion beyond /code-review. Deep panel review for the Watchtower repo (Go CLI + SwiftUI Desktop) — prosecutor + codex + three pr-review-toolkit specialists in parallel, synthesised by a judge against the project ruleset in docs/review/review-rules.md. Pass "verify" for a cheap post-fix verification round (codex + judge only).
---

# Debate Review (slim panel)

Deep review without the debate: an adversarial Claude **prosecutor**, an independent **codex** review, and three `pr-review-toolkit` specialists (`pr-test-analyzer`, `silent-failure-hunter`, `pr-review-toolkit:code-reviewer`) run in one parallel batch; a **judge** synthesises the final verdict from all lanes. You are a thin orchestrator — all agents are read-only: they inspect the diff and repo but never edit files or run git/network mutations.

> History: this skill used to run a full adversarial debate (advocate vs prosecutor + rebuttal rounds). The 2026-08-08 session analysis showed the advocate/rebuttal lanes added almost no unique catches while the judge already performed their function (dismissing weak findings), so they were removed — see `docs/superpowers/specs/2026-08-08-review-slim-design.md`.

## Inputs

- **Review target**: current branch diffed against a base (default `main`), or a PR via `gh pr diff <PR#>`. Specify with `--base <branch>` or `--pr <PR#>`.
- **verify**: flag for a post-fix verification round — codex + judge only, see below. Used by `local-review` on convergence rounds 2+.
- **comment**: flag to post findings as inline PR comments after printing the report (default off — print only).
- **outcome mode**: `--outcome <PR#>` — instead of running a review, record the real-review result of a past run into the lessons log (see Outcome feedback). This is the strong self-learning signal.

## Step 0 — load ruleset

Read `docs/review/review-rules.md`. If it is absent, bootstrap it from the nine dimension headers (see `references/agent-prompts.md`) and continue. Graceful-empty: a sparse ruleset is fine — all agents fall back to the dimension definitions in `references/agent-prompts.md` plus project best practices (`CLAUDE.md`, `docs/inventory/`).

`review-rules.md` is **binding** and goes to every agent. `docs/review/review-lessons.md` (soft calibration) is **judge-only**, and the judge reads only the tail — the last ~10 blocks. Do not feed the lessons log to the prosecutor or the specialists.

## Step 1 — panel (parallel)

Get the diff:

- Branch mode: `git diff <base>...HEAD`
- PR mode: `gh pr diff <PR#>`

Dispatch in one parallel batch:

1. The **prosecutor** — `subagent_type: "review-prosecutor"` (Agent tool, session model). The deep adversarial lens: checkable findings (file:line + rule ref) across the nine dimensions.
2. The **codex** run — dispatch the `codex-wrapper` agent (`subagent_type: "codex-wrapper"`); set `BASE_BRANCH` to the same base. codex runs on a separate billing pool (no Claude tokens, no session-limit risk) and has been the top unique-catcher — never skip it to "save cost".
3. The **`pr-review-toolkit` specialist trio** — each with `model: "sonnet"` on the Agent call (focused single-lens pattern-matchers; the deep-reasoning budget belongs to the prosecutor and the judge):
   - `subagent_type: "pr-review-toolkit:pr-test-analyzer"` — behavioural coverage gaps (rated 1–10).
   - `subagent_type: "pr-review-toolkit:silent-failure-hunter"` — swallowed errors, unlogged catches.
   - `subagent_type: "pr-review-toolkit:code-reviewer"` — general quality against the toolkit's ruleset. **Always with the `pr-review-toolkit:` prefix.**

All five calls are independent and read-only, so the parallel dispatch is safe — no worktree needed.

The `review-prosecutor` agent (`.claude/agents/`) already carries its persona, the nine dimensions, and the read-only tool boundary. Pass it only the **inputs** for this run: the diff and the path/contents of `docs/review/review-rules.md`. The specialists carry their own personas from the plugin; pass them only the diff.

Collect all five outputs before proceeding. codex and each specialist are best-effort: codex is wrapped in `timeout` (see `references/agent-prompts.md`); for each specialist, if it stalls or yields no verdict, proceed with what came back and mark that lane `unavailable` for the judge — never block the review on a stuck reviewer. The prosecutor is not best-effort — if it fails, retry once; if it fails again, escalate (the panel cannot proceed without its primary lens).

## Step 2 — judge

Dispatch the judge as `subagent_type: "review-judge"` (session model) with the prosecutor's findings, the codex findings, the specialist outputs (any that ran), the ruleset, and the nine dimensions as inputs (its persona and report format live in the agent definition, mirroring `references/agent-prompts.md`). The judge ALWAYS runs — it provides the independent synthesis that merges all lanes and dismisses weak findings (the function the removed advocate used to serve).

The judge dedupes across lanes (overlaps are expected — simplicity findings often show up across the prosecutor and `code-reviewer`; coverage gaps from `pr-test-analyzer` often echo what the prosecutor raised). When a finding is raised by multiple lanes, the judge keeps one entry and records "raised by N lanes" — that agreement is signal, not noise.

Findings the judge genuinely cannot settle surface under "Needs human" — never silently dropped.

## Verification mode (`verify`)

For convergence rounds after fixes (dispatched by `local-review` rounds 2+, or on request):

1. Dispatch **codex only** (`codex-wrapper`), pointed at the post-fix diff, with the list of findings fixed last round so it verifies the fixes AND looks at the changed hunks fresh. If codex reports unavailable, substitute the **prosecutor** — a verify round never runs on zero reviewers.
2. Dispatch the **judge** with the reviewer's output + the fixed-findings list. Same report format; the reflection append is **skipped** on verify rounds (one lesson block per review, not per round).

No prosecutor, no specialists — a fix-verification round does not need fresh whole-diff discovery.

## Output

Print the judge's report (format defined in `references/agent-prompts.md`): verdict (`approve` / `changes-needed`), blockers, major/minor/nits grouped by severity, "Needs human" items, and a summary paragraph.

If `--comment` was passed, post each finding as an inline PR comment at its `location` — one comment per finding, same as `/code-review --comment`.

## Step 3 — reflect & learn

After the verdict (full runs only — not verify rounds), the judge appends ONE dated block to `docs/review/review-lessons.md` so the system calibrates over time. Capture only what is worth remembering — contested points the judge had to settle, false-positives (raised then dismissed), misses (caught only by codex / late / by a human), weak dimensions, and rule gaps. Use the reflection entry format in `references/agent-prompts.md`. This is an observation log — the judge never edits `review-rules.md`.

## Outcome feedback (`--outcome <PR#>`)

The strongest learning signal is the real outcome, not the judge's own opinion. In outcome mode the orchestrator does not run a review: it asks the operator which findings actually held up after the real human review / merge, and records them on the matching lesson block's `outcome:` line (format in the reference). Never invent outcomes — record what the operator reports.

## Promotion (gate against learning the wrong thing)

Auto-entries in `review-lessons.md` never become binding rules on their own. When a lesson proves out, the operator promotes it into `docs/review/review-rules.md` under the matching dimension and marks it `[promoted]` in the lessons log. This two-tier split (free auto-log → operator-gated binding rules) keeps the system from reinforcing a wrong lesson.

## Anti-patterns

- **Never skip the judge.** Even a clean-looking panel needs the independent synthesis — it is not a rubber-stamp.
- **Never skip codex.** It is the only lane outside Claude's token/limit pool and the top unique-catcher; it is best-effort on availability, never optional by choice.
- **Never drop findings the judge could not settle.** Surface every one under "Needs human" in the report; do not silently discard them.
- **Never invent findings.** Prosecutor findings must be checkable (file:line, rule reference). Vague or fabricated issues are disqualified.
- **Agents are read-only.** None of the agents in this skill (prosecutor, codex, the specialists, judge) may edit files, commit, push, or run any mutation — except the judge's single reflection append. The orchestrator also makes no edits during review.
- **Always dispatch `pr-review-toolkit:code-reviewer` with the namespace prefix.** A bare `subagent_type: "code-reviewer"` is not a Watchtower agent — the toolkit's `code-reviewer` lens then goes silently missing from the judge's inputs.
- **Never feed the lessons log to the whole panel.** It is judge-only, tail-only (~10 blocks) — the full-file-to-every-agent pattern was the old design's biggest fixed cost.
- **Never run a full panel as a verify round.** Rounds 2+ of a convergence loop use `verify` (codex + judge); full discovery is round-1 work.
- **Never auto-promote lessons to rules.** `review-lessons.md` is observations only; the operator moves a lesson into `review-rules.md`. In `--outcome` mode never invent outcomes — record what the operator reports.

## References

- `.claude/agents/review-prosecutor.md`, `review-judge.md` — the two personas as first-class subagents (persona + tool boundary). Dispatch them by `subagent_type`; `references/agent-prompts.md` remains the source of truth their prompts mirror.
- `.claude/agents/codex-wrapper.md` — the codex voice (best-effort, wrapped in `timeout`).
- `references/agent-prompts.md` — prompt templates for prosecutor and judge; the codex command; the nine dimension definitions; the finding schema and report format.
- `docs/review/review-rules.md` — project-specific binding rules loaded by every agent.
- `docs/review/review-lessons.md` — auto-learning log (reflections + outcomes); judge-only calibration; operator-gated promotion into the rules.
- `docs/superpowers/specs/2026-08-08-review-slim-design.md` — the decision record for dropping the debate.
