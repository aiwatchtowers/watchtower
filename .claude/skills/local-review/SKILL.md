---
name: local-review
description: Quality gate for Watchtower changes before any PR. Runs the local CI mirror (gofmt + go vet + golangci-lint + go build, plus swift build/lint when Desktop changed) and the affected tests, then reviews — on per-item reviews a round-1 panel (codex via the codex-wrapper agent + pr-review-toolkit:code-reviewer + the style-guardian agent + pr-review-toolkit:silent-failure-hunter), narrowing to codex alone (code-reviewer as fallback) on rounds 2+; on the final PR into the base branch the deeper debate-review skill instead (full panel round 1, verify mode on rounds 2+) — and critically triages every finding (accept, reject with reason, defer) before fixing, looping until the reviewers converge. Use before opening a PR, or standalone when the user says "review my changes", "run the checks", "codex review", or wants the local pipelines run before a PR.
---

# Local Review

You run the quality gate for Watchtower changes before any PR is opened. This skill covers four things: running the local CI mirror, running review, critically triaging every finding, and **looping until the reviewers converge on zero accepted findings**. Nothing opens to review until the loop has converged (or escalation is recorded).

**Who applies fixes.** Accepted code fixes are applied inline (or by dispatching a
`general-purpose` subagent with the triaged change list for a large batch). Triage decisions,
the state of the loop, and this report are the orchestrator's own.

## When to run

Run this skill after writing or modifying code and before it merges anywhere — whether that is a per-branch review before a sub-branch merges into the feature branch, or the final PR against the base branch (default `main`). It is also triggered standalone when the user asks to "review my changes", "run the checks", "codex review", or wants local pipelines run before a PR.

## Step 1 — local CI gate

Run, in order, and keep only exit codes + `tail` of failures in context (full logs stay on disk — do not `cat` whole outputs into the conversation):

1. **Format & vet (Go).** `gofmt -l $(git diff --name-only main... -- '*.go')` must print nothing; `go vet ./...` must pass.
2. **Lint & build.** `make lint` (`golangci-lint run ./...`) and `make build` (`go build`) — both clean. If the change touches `WatchtowerDesktop/`, also `make lint-swift` and `cd WatchtowerDesktop && swift build`.
3. **Anti-pattern guardrail over the diff.** grep the changed files for the patterns that recurred on past reviews:
   - a weakened/renamed/split `docs/inventory/` guard test (`Test<Module>NN_` convention) — these are load-bearing; a change here is **stop-and-ask-the-owner**, not a review nit;
   - `db.Open(":memory:")` (or `sql.Open` on `:memory:`) without a `SetMaxOpenConns(1)` nearby — the transaction-opens-a-fresh-empty-DB gotcha;
   - duplicate `HandleFunc` registration in test mux setup (Go 1.25 panics) — custom `conversations.history` tests must use `baseMux()`, not `defaultMux()`;
   - any `CLAUDE_CONFIG_DIR` override (breaks keychain auth) — TCC isolation goes through `--setting-sources`.

   Treat each hit as accept-by-default in Step 3; fix unless you can justify it.
4. **Run the affected tests.** `go test ./... -race` for the packages the change touches (a real run with the race detector is the only thing that catches data races and `:memory:` connection bugs that compile fine). If Desktop changed: `make test-swift`.

If anything fails, fix it before proceeding to review. Red checks make review feedback moot until the code actually builds and the tests pass.

## Step 2 — review (mode-aware on `BASE_BRANCH`)

Which reviewer runs depends on the merge target. Set `BASE_BRANCH` to the feature branch for a per-branch review, or to the base branch (`main`) for the final PR.

### Per-branch review (`BASE_BRANCH = feature/<...>`) — parallel review panel

**Round 1** runs the full panel (four voices); **rounds 2+** narrow to codex alone — the token cost of a full panel every round is real, post-fix rounds are about verifying fixes rather than re-discovering the diff, and codex runs outside Claude's token/limit pool. Dispatch each round's voices in one parallel batch.

**Round-1 panel** — the discovery lenses:

- **Codex (best-effort, correctness)**: dispatch the `codex-wrapper` agent (Agent tool, `subagent_type: "codex-wrapper"`) with `BASE_BRANCH`. The wrapper owns the canonical `codex review` command, output parsing, and `file:line` verification, and returns the codex findings list. **Codex is not a hard gate** — if the wrapper reports "codex unavailable (<reason>)", do NOT block: proceed with the remaining reviewers and record the line in the report.
- **`pr-review-toolkit:code-reviewer` (broad review)**: dispatch it (Agent tool, `subagent_type: "pr-review-toolkit:code-reviewer"`) on the branch diff. Collect its findings — correctness, reuse, missing assertions, the usual mixed bag.
- **`style-guardian` (style + simplicity)**: dispatch the `style-guardian` agent (Agent tool, `subagent_type: "style-guardian"`) on the same diff. It narrows to two questions only — "is the code maximally simple, no излишества" and "does it match house style per `docs/review/review-rules.md`". Its findings overlap with the other reviewers on style; the dedup step in Step 3 collapses it.
- **`pr-review-toolkit:silent-failure-hunter`**: swallowed errors, fallback paths that mask failure. Best-effort like codex; if it fails or times out, proceed and note "silent-failure-hunter unavailable" in the report.

**Rounds 2+ (verification)** — **codex alone**. Point it at the post-fix diff and list the findings fixed last round so it verifies the fixes AND looks at the changed hunks with fresh eyes. If (and only if) the wrapper reports "codex unavailable", substitute `pr-review-toolkit:code-reviewer` for that round — a verification round never runs on zero reviewers, but it also never runs both. `style-guardian` and `silent-failure-hunter` do not re-run: a whole-diff re-sweep every round costs more than it finds.

Dispatch each round's panel concurrently — the reviewers are independent and read-only, so parallel dispatch is safe. Collect all outputs before triage.

**Panel composition is fixed.** The four round-1 voices and the rounds-2+ codex (with its documented fallback) ARE the complete per-branch panel. Do NOT widen either — extra reviewers' findings collapse as duplicates in dedup while their cost is real. The full specialist `pr-review-toolkit` panel is final-PR territory (it runs inside `debate-review`).

### Final PR (`BASE_BRANCH = main`) — debate-review instead

On the final PR run the project `debate-review` skill **instead of** the panel above (Skill tool, `skill: "debate-review"`; pass `--base main`). It already runs `codex` internally — in parallel with a prosecutor and three `pr-review-toolkit` specialists — and a judge synthesises a verdict + prioritised findings across the nine dimensions in `docs/review/review-rules.md`. That makes it a **superset** of the per-branch panel, so do **not** also run codex + the panel on top: stacking re-runs codex 2–3× for no extra signal. `debate-review` appends its own reflection to `docs/review/review-lessons.md` (normal side effect). Feed the judge's prioritised findings into the triage in Step 3.

**Full panel runs once.** On rounds 2+ of the convergence loop invoke `debate-review` with `verify` — codex + judge only, told which findings were just fixed. A fix-verification round does not need fresh whole-diff discovery.

## Step 3 — critical triage

### 3a — Dedup first (per-branch review only)

You have up to four lists on round 1 (codex, `pr-review-toolkit:code-reviewer`, `style-guardian`, `silent-failure-hunter`) and one on rounds 2+ (codex, or its fallback) that **will** overlap on round 1. Before triaging, collapse them into one prioritised list:

1. Group findings by `file:line` + claim. If multiple reviewers raise the same issue, keep one entry and record "raised by N reviewers" — that is signal, not noise.
2. Near-duplicates count: same file, same rule, slightly different wording → one entry, citing the strongest version.
3. Order the deduped list by severity (blocker / major / minor / nit), then by file.

On the final PR you skip 3a — `debate-review`'s judge already produced one deduped, prioritised list.

### 3b — Triage

For **each** finding, decide one of three dispositions:

- **accept** — real issue; fix it now.
- **reject** — false positive or wrong for this codebase; record one-line reason.
- **defer** — valid but out of scope; note as a follow-up item.

Do not blanket-apply suggestions. A rejected finding requires a reason. Apply accepted fixes in **one batch per round**, then re-run the local CI gate (Step 1) to confirm nothing broke, and continue to Step 4 — the loop is not done until the reviewers say there is nothing to fix.

## Step 4 — convergence loop

A single review pass is not a guarantee. After applying accepted fixes, reviewers see a different diff and may surface fresh findings (drift). The exit criterion is **semantic, not iterative**: keep looping until a fresh review round produces **zero accepted findings**.

```
round = 1
loop:
    run Step 1 (CI gate; -race test run every round, swift test only if Desktop changed)
    run Step 2 (reviewers) — same lens as the first pass for the BASE_BRANCH
    run Step 3 (dedup + triage)
    if accepted findings == 0:
        record `converged in <round> round(s)` in the report; exit clean
    apply accepted fixes; commit to the same branch
    round += 1
    if round > 7:
        record `cap hit (7 rounds), residual: <count> accepted` in the report; escalate
```

Notes:

- **Defer and reject do NOT block.** A round with only deferred / rejected findings counts as converged. Defer entries go into the report's `Deferred` section; reject entries go into `Rejected` with their reason. Only `accept` keeps the loop going.
- **Same reviewer mode each round, narrowed composition after round 1.** Per-branch `BASE_BRANCH=feature/<...>` → the full four-voice panel on round 1, codex alone (code-reviewer fallback) on rounds 2+; final PR `BASE_BRANCH=main` → full `debate-review` on round 1, `debate-review` with `verify` on rounds 2+. Don't switch modes (panel ↔ debate-review) mid-loop.
- **Codex unavailability is not a cap-hit.** If the wrapper reports unavailable on a round, the round still counts; record `codex unavailable round N` and rely on the remaining reviewers.
- **Drift detection.** If two consecutive rounds raise the **same** finding that was supposedly fixed, the fix is wrong — escalate early. Record `drift on <file:line> after round N` and stop the loop.
- **Cap = 7.** Chosen so genuine convergence on a non-trivial diff fits, but a thrashing loop terminates. On cap-hit, return the residual accepted list with `accepted-after-cap: <list>` so the operator decides — never silently proceed.

## Output

Produce a short report with six sections:

1. **CI gate** — pass / fail on the final round; list any errors that required fixing.
2. **Convergence** — one of `converged in <N> round(s)` / `cap hit (7 rounds), residual: <count> accepted` / `drift on <file:line> after round N — escalated`. Add `codex unavailable round X` lines if a round had a best-effort reviewer down.
3. **Findings** — final-round counts: per-reviewer before dedup + total after dedup (per-branch), or `debate-review`'s judged count (final PR).
4. **Fixed** — accepted findings (across all rounds) and the change made for each.
5. **Rejected** — rejected findings with one-line reasons.
6. **Deferred** — deferred findings noted as follow-ups.

A clean exit means **Convergence = `converged in N round(s)`** AND **final-round accepted = 0**.

## Anti-patterns

- **Never open a PR on red local checks.** If `make lint`, `make build`, `go vet`, or any affected test fails, the PR waits.
- **Never apply every bot suggestion uncritically.** Each finding must be triaged, not rubber-stamped. A rejected finding needs a reason.
- **Do not skip the `-race` test run.** A change that compiles but races or hits the `:memory:` connection bug is broken regardless of a green build.
- **Never weaken a `docs/inventory/` guard test to make a check pass.** That is stop-and-ask-the-owner, per `CLAUDE.md`.
- **Never widen the panel beyond the documented voices.** Extra reviewers ≠ extra signal.
- **Do not triage before the gate is green.** Fix first, review second.
- **Never stack `debate-review` on top of the per-branch panel.** On the final PR `debate-review` replaces the panel, it does not add to it.
- **Never exit on a single round when there were accepted findings.** Re-run the reviewers on the post-fix diff.
- **Never silently proceed on a cap hit.** Return the residual list and let the operator decide.
