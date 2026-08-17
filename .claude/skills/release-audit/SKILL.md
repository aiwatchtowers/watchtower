---
name: release-audit
description: Use when the user wants a release-candidate audit — "audit this release", "audit the RC", "review everything since the last tag", or wants a broad multi-lens sweep over a git range rather than a single-diff review. Dispatches five parallel read-only auditors (Product, Functional correctness, Security, Bugs, Code quality) across the range's merged PRs, then synthesises a deduplicated, severity-ranked report. Heavier and broader than `debate-review` (which reviews one diff); use this for "what shipped since X, is it safe".
---

# Release-Candidate Audit

A whole-range audit: instead of reviewing one diff, this walks every PR merged into a range and runs five independent lenses over the accumulated change, then merges their findings into one ranked report. Use it before cutting a release, or whenever the ask is "what shipped since X" rather than "review this branch".

## When to run

User says "audit the release", "audit RC", "what's the risk in this release", "review everything since the last tag/release", or names a range/PR set and wants a broad sweep rather than a targeted diff review. Not a substitute for `local-review`/`debate-review` on an individual PR — those stay the pre-merge gate; this runs after PRs have already landed, over the accumulated range.

## Step 1 — pick the range

Default target: latest tag → `HEAD`. Resolve it:

```
git tag --sort=creatordate | tail -5      # find the most recent tag
git log --merges --oneline <from>..<to>   # enumerate merged PRs in range
```

If the user names an explicit range (`vX.Y.Z..vA.B.C`) or a PR list, use that instead of the tag default. For each merge commit found, get its isolated diff:

```
git diff <merge>^1..<merge>
```

Build the full picture from two things: the range-wide diff (`git diff <from>..<to>`) for cross-cutting sweeps, and the per-PR merge diffs for attributing a finding to the PR that introduced it. Note the range and merge list in the eventual report so findings can be traced back to a PR number.

## Step 2 — five parallel auditors

Dispatch all five in **one message** (multiple Agent tool calls in the same turn) — they are independent and read-only, so parallel execution is always safe. If dispatched as background agents, the controller collects each one's final report via `SendMessage` before synthesising.

Every brief must state, verbatim or adapted:

- **Read-only.** Inspect, do not edit, do not run mutating git commands.
- **Prioritise `internal/` (Go) and `WatchtowerDesktop/Sources` (Swift) over test files** — tests matter for coverage gaps, but the audit's job is production-code risk.
- **Cite `file:line`** for every finding — no unattributed claims.
- **Check the relevant `docs/inventory/` contracts** for any touched module (`inbox-pulse.md` INBOX-NN, `dashboard.md` DASH-NN, `memory.md` MEM-NN, `ideas.md` IDEA-NN, `features.md` FEAT-NN, `dev-surface.md` DEV-NN, and any others under `docs/inventory/`) — a change that weakens or drifts from a numbered contract is at minimum High severity.
- **Return findings ranked by severity** (Critical/High/Medium/Low) **with a concrete failure scenario** for each — not "this could be an issue" but "if X happens, Y breaks because Z".

### Auditor 1 — Product

`subagent_type: "general-purpose"`. Lens: does the shipped range make sense as a product change? Gaps between what a feature note in `CLAUDE.md` / `docs/superpowers/specs/` promises and what the code actually does; half-finished flows (a Desktop screen with no way to reach it, a CLI flag nothing wires up); UX regressions; anything that reads as shipped-but-not-really-done.

### Auditor 2 — Functional correctness

`subagent_type: "general-purpose"`. Lens: does the code do what it claims? Logic errors, wrong conditionals, off-by-ones, incorrect state machines, watermark/floor math, wrong dual-path renderers (Go↔Swift contracts in `CLAUDE.md`'s feature notes are full of these — segments/notes/recap dual-path precedents). Trace at least one representative flow per touched module end-to-end rather than skimming diffs in isolation.

### Auditor 3 — Security

`subagent_type: "general-purpose"`. Lens: new or regressed exposure only. **First read `docs/security-audit-2026-07-31.md` §8 (or the latest `docs/security-audit-*.md`) as the accepted baseline** — do not re-report anything already catalogued there as known/accepted. Only report what is NEW in this range or a REGRESSION of a previously-fixed issue: secrets in argv/logs, token storage deviating from the file-0600 convention (`project_token_storage_file_vs_keychain.md`), TCC-prompt-triggering APIs (`feedback_no_tcc_prompts.md` — any Accessibility/global-monitor API is P0), SQL injection, auth-state handling that silently downgrades to "ok", account-scoping gaps (cross-account data leakage in the multi-account features), CASA/Limited-Use exposure in Gmail-content handling.

### Auditor 4 — Bugs

`subagent_type: "review-prosecutor"`. This agent already carries the adversarial persona and the nine review dimensions from `docs/review/review-rules.md` — pass it the range diff and merge list as inputs, told explicitly this is a multi-PR range audit, not a single-diff review. Let it run its normal adversarial sweep across the whole range.

### Auditor 5 — Code quality

`subagent_type: "style-guardian"`. This agent already narrows to simplicity + house-style adherence. Pass it the range diff; ask it to flag accumulated drift across the range (duplicated patterns that should have converged, dead code left behind by superseded features, `docs/review/review-rules.md` Swift/Desktop convention violations) in addition to its normal per-diff pass.

## Step 3 — synthesis

Once all five reports are in, produce one deduplicated, ranked report:

1. **Dedupe.** Same `file:line` + same underlying claim across two or more auditors → one finding, note "flagged by N auditors" (that is agreement, not redundancy) and keep the highest severity assigned by any of them.
2. **Rank.** Group into Critical / High / Medium / Low. A finding that touches a `docs/inventory/` contract number is never below High.
3. **Attribute.** Where possible, note which PR (from the merge list in Step 1) introduced each finding.
4. **Report shape**: range audited, PR/merge list, then the four severity buckets, then a short "Needs owner decision" section for anything ambiguous or contract-adjacent.
5. Optionally publish the report as an Artifact (load `artifact-design` first per that tool's contract) when the report is long enough that a scrollable formatted page beats a terminal wall of text — the user's call if unclear.

## Guardrails

- **Read-only throughout.** No auditor edits code, and neither does the synthesis step. This skill produces a report, not a fix.
- **Never auto-fix findings.** Findings go to the user/owner for triage, same as `docs/inventory/README.md`'s protocol — this skill does not loop-and-fix like `local-review`.
- **Inventory-contract findings stop for an owner decision.** Anything that implicates a numbered `docs/inventory/` contract (or its guard test) must be flagged for explicit owner sign-off per `CLAUDE.md`'s Behavior Inventory protocol — do not resolve it in the report as if it were an ordinary bug.
- **Don't skip the security baseline read.** Reporting an already-accepted/known issue as new noise defeats the point of the baseline diff in Auditor 3.

## References

- `docs/review/review-rules.md` — the nine review dimensions, Swift/Desktop conventions.
- `docs/inventory/README.md` — module → contract file mapping; the stop-and-ask-the-owner protocol.
- `docs/security-audit-2026-07-31.md` §8 — accepted security baseline.
- `.claude/agents/review-prosecutor.md`, `style-guardian.md` — personas used by Auditors 4–5.
- `debate-review`, `local-review` — the per-diff/per-PR review skills this audit complements, not replaces.
