# debate-review agent prompts and schemas

Every panel agent receives: the diff under review, the contents of `docs/review/review-rules.md`
(binding rules), and the nine dimension definitions below. The lessons log
(`docs/review/review-lessons.md`) is **judge-only**, tail-only (last ~10 blocks). Agents are
READ-ONLY — they inspect the diff and repo, never edit or run git/network mutations.

Watchtower is a Go 1.25 CLI (`watchtower`, module `watchtower`, SQLite via
`modernc.org/sqlite`) plus a SwiftUI macOS Desktop app (`WatchtowerDesktop/`, GRDB.swift).
Reviewers must understand both halves; many changes touch the Go pipeline and the Swift UI
that reads the same SQLite DB.

## Nine dimensions

1. **arch-style** — follows the project's architectural style. Go: `internal/<domain>/`
   package layout, interface seams (`ai.Provider`, `digest.Generator`), daemon phase ordering.
   Swift: Models → Queries → ViewModels (`@MainActor`, `@Observable`) → Views, GRDB
   `ValueObservation`. Behavioural contracts in `docs/inventory/` are load-bearing.
2. **arch-decision** — the architectural decision is sound for the problem; does not spin up a
   parallel pipeline/table where an existing one fits.
3. **code-style** — idiomatic Go (`gofmt`, error wrapping with `%w`, no stutter) and Swift
   naming; matches project conventions and neighbour files.
4. **efficiency** — no needless work, queries, or allocations; watch SQLite N+1 and batch
   writes; never force a full Slack sync where incremental/search sync suffices.
5. **codebase-fit** — reuses existing helpers/tables/patterns (mock `digest.Generator`,
   `baseMux()`, shared queries) rather than duplicating them.
6. **ac-correctness** — actually solves the ticket / acceptance criteria, not just "looks nice".
7. **test-quality** — tests assert behaviour and fail when the feature breaks; no happy-path
   tests with no assertion, no `if`-guarded skips. Go: table tests, `-race`-clean, mock the
   AI generator (never call the live `claude`/`codex` subprocess), `:memory:` DBs use
   `SetMaxOpenConns(1)`, custom `conversations.history` tests use `baseMux()` not
   `defaultMux()`. The `docs/inventory/` guard tests (`Test<Module>NN_`) must NOT be weakened,
   renamed out of convention, or split into weaker tests. Swift: XCTest covers the new path.
8. **regression** — blast radius; what else could break; backward-compat of the DB schema
   (migrations are forward-only and versioned), CLI flags, and public Go interfaces.
9. **dry-errors-security** — duplication, swallowed errors (caught/ignored without log or
   return), no leaked credentials/tokens, parameterised SQL. A macOS TCC prompt triggered by
   `Watchtower.app` is a P0 — fix the responsibility chain, never the symptom.

## Finding schema (JSON, one per issue)

```json
{ "id": "F1", "dimension": "test-quality", "severity": "blocker|major|minor|nit",
  "location": "internal/inbox/pipeline.go:42", "claim": "one sentence", "rule_ref": "review-rules §7 bullet, or none" }
```

## Prosecutor prompt

```
You are the PROSECUTOR in an adversarial code review. Find everything wrong with this change.
Diff / rules / dimensions: <as above>

Produce findings (Finding schema), one per real issue, tagged by dimension + severity,
with file:line and a rule_ref when a rule applies. Be ruthless but precise — no vague or invented
issues; each must be checkable. You are read-only.
```

## Codex (independent, parallel)

```bash
timeout 300 codex review --base "$BASE" -c sandbox_mode="read-only" -c approval_policy="never"
```

`codex review` (codex 0.130+) is the dedicated non-interactive review subcommand;
`-c sandbox_mode="read-only"` lets it read anything but mutate nothing, and
`-c approval_policy="never"` stops it blocking on approval prompts — together they replace
the old `--dangerously-bypass-approvals-and-sandbox` flag, which the Claude Code auto-mode
permission classifier REJECTS as an unsandboxed autonomous loop. Run against the same base
as the panel (default `main`). Capture stdout as an independent findings list. For a PR
target, review the PR branch's diff against its base.

codex runs on a separate billing pool — it consumes no Claude tokens and cannot trigger a
session-limit pause — which is why it is also the sole reviewer on `verify` rounds.

**codex can hang, time out, or drop into a reconnect loop.** Wrap it in `timeout` and treat it
as best-effort: if it yields no verdict within the limit, proceed with the prosecutor /
specialist outputs alone and mark the codex lane `unavailable` in the judge inputs — never let
a stuck codex stall the review. (On a `verify` round, an unavailable codex is substituted by
the prosecutor instead.)

## Judge prompt

```
You are the JUDGE. You did not participate in the review. Inputs:
- The prosecutor's findings list
- The codex findings list
- The pr-review-toolkit specialist outputs (or `unavailable` per lane)
- Project rules + the nine dimensions
Produce the FINAL verdict and report (schema below). Dismiss findings that do not hold up
(check them against the code); merge/de-duplicate across lanes ("raised by N lanes" is
signal). Items you genuinely cannot settle go under "Needs human" — never silently drop
them. Prioritise by severity.
```

## Report format (judge output)

```markdown
## Verdict: approve | changes-needed

### Blockers

- [dimension] location — claim _(prosecutor: …; codex: …; rule: …)_

### Major / Minor / Nits

- ... grouped by severity ...

### Needs human (unresolved)

- ... items the judge could not settle ...

### Summary

One paragraph: the decisive points and why the verdict.
```

## Reflection (judge appends to `docs/review/review-lessons.md`, full runs only)

After the verdict, the judge writes ONE dated block to `docs/review/review-lessons.md` so the
system calibrates over time. Capture only what is worth remembering — not a re-statement of
the report:

```markdown
## <date> — <branch or PR#> — verdict: <approve|changes-needed>

- contested: <point the judge had to settle> [dimension]
- false-positive: <finding raised then dismissed, and why> [dimension]
- miss: <issue caught only by codex / late / by a human> [dimension]
- weak-dimension: <dimension that underperformed>
- rule-gap: <rule that was missing or that proved useful>
- outcome: <leave as TBD — filled later by the --outcome step>
```

This is an observation log, NOT a rule edit. The judge never edits `review-rules.md`.

## Outcome record (`--outcome <PR#>` mode)

After the real human review / merge, the operator records which findings actually held up.
Append to (or update) the matching lesson block's `outcome:` line:

```
- outcome: F1 confirmed (real bug, merged with fix) ; F3 was a false alarm (reviewer dismissed) ; human added: missing migration guard
```

The orchestrator does not invent outcomes — it records what the operator reports. Confirmed
lessons are later promoted by the operator into `review-rules.md` (marked `[promoted]`).
