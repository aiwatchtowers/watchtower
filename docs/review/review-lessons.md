# Review Lessons

Soft-calibration log for `debate-review`. The judge appends ONE dated block per run (Step 4
reflection); the operator later fills the `outcome:` line after the real human review / merge
(`debate-review --outcome <PR#>`). **Observations, not binding rules** — every review agent
reads this as calibration. When a lesson proves out, the operator promotes it into
`docs/review/review-rules.md` under the matching dimension and marks it `[promoted]` here.

Entry format:

```markdown
## <date> — <branch or PR#> — verdict: <approve|changes-needed>

- contested: <unresolved point the judge had to settle> [dimension]
- false-positive: <finding raised then dismissed, and why> [dimension]
- miss: <issue caught only by codex / late / by a human> [dimension]
- weak-dimension: <dimension that underperformed>
- rule-gap: <rule that was missing or that proved useful>
- outcome: <TBD until the --outcome step records the real result>
```

---

<!-- judge appends new lesson blocks below this line -->

## 2026-06-16 — feature/catch-up-summarizer — verdict: changes-needed

- contested: F5 — silent-failure-hunter framed the dropped `parseAIOutput` perr as "removed pipeline_runs telemetry not replaced"; verified against `git show 27c8d8e:cmd/catchup.go` that the old command had NO telemetry, so that premise is false. Settled as a real but narrower minor: an invalid-JSON AI response degrades silently with no log, which is hard to diagnose. By-design degradation is fine; invisible degradation is not. [9 error-handling]
- contested: F7 — prompt example uses singular `"area":"track"` vs plural section areas. Confirmed `refs.area` only feeds the SwiftUI `CatchUpRef.id` string; no matching/clearing depends on it. Demoted to nit/latent, but worth fixing because the prompt teaches the model the wrong vocabulary. [3 code-style]
- false-positive: F8 (stopObserving never called / totalTrackCount unread) — app-lifetime VM, demoted to nit; not load-bearing. [1 architecture]
- miss: F9 (nil Go slice → JSON `null` → Swift non-optional decode throws "Failed to parse catch-up") slipped past the internal panel AND the smoke test (smoke ran with all four areas non-empty so no slice was nil) AND both Go and Swift test suites (Swift fixtures hardcode full arrays; Go tests never assert the wire shape of empty slices). Caught only by codex + debate, empirically reproduced both sides. The single most common runtime path (zero-unread early return) hits it. [6 AC / 7 tests]
- miss: codex first-run badge — `SidebarCountsViewModel` is a NEW file this branch; its only construction site is the `!needsOnboarding` path in `initialize()`, and `completeOnboarding()` never creates it → first-run users see all sidebar badges (incl. Catch-Up) at 0 until restart. Branch-introduced, not pre-existing. Caught only by codex. [6 AC]
- weak-dimension: 7 (test quality) — both Go and Swift suites were green and numerous (807 Swift), yet neither exercised the empty-slice wire shape (F9) nor the SidebarCountsViewModel (untested). Green + high count masked the headline defect. Coverage-driven dead code (F2/F10) further inflated the count without exercising production paths.
- rule-gap (proved useful, candidates to promote): (a) Go↔Swift JSON contract — a nil Go slice marshals to `null`, and a non-optional Swift `[T]` then throws DecodingError; initialise slices to `[]T{}` (or omitempty + Swift optional/default) and add a test asserting the empty-state wire shape, dim 8/9. (b) Desktop mark-read must not clear UI state before the DB write succeeds — `try?` + unconditional `clearSectionLocally`/`result=nil` makes the UI lie on a WAL-locked write; mirror DigestViewModel do/catch and only clear on success, dim 9. (c) A new sidebar/badge ViewModel must be constructed on every path that reveals the sidebar (both `!needsOnboarding` and `completeOnboarding`), dim 6.
- outcome: TBD

## 2026-06-16 — feature/catch-up-summarizer (re-review, +7 fix commits) — verdict: approve

- re-review: confirming pass after `changes-needed`. All prior blockers verified CLOSED in code (not just claimed): F5 now logs both AI-rollup and unparseable-output degradation (`internal/catchup/pipeline.go:83,91`); mark-read do/catch + only-clear-on-success landed; F9 empty-slice wire shape fixed; SidebarCountsViewModel constructed on the onboarding path and its `fetch()` wraps the read in do/catch with a log. Four lanes agree (prosecutor2, codex2, silent-failure2, toolkit-reviewer2 approved). go build/vet/test/lint clean; swift build OK, 811 tests green, swiftlint --strict clean.
- contested: codex2 pipe-deadlock (CatchUpViewModel.runCLI stdout-then-stderr sequential drain, >64KB stderr could block). Verified `internal/`... actually `CatchUpViewModel.swift:269-270`: data IS read before `waitUntilExit` (the prior deadlock class), but two pipes are still drained sequentially. Settled as PRE-EXISTING shared-runner tech debt (same pattern in MeetingPrepViewModel), NOT introduced by this feature → not a blocker for this branch. Follow-up: concurrent drain in the shared CLI runner. [9 error-handling]
- follow-ups (none blocking): (1) pipe sequential-drain deadlock risk in shared CLI runner [pre-existing, dim 9]; (2) truncation UX over-promise — "Mark everything read" with truncated=true caps the snapshot and shows "all caught up" while "+N not shown" rows stay unread in DB [inherent to capping design, dim 6]; (3) internal `try?` in SidebarCountsViewModel.fetch() for inbox/recs counts silently fall back to 0 with no log [pre-existing advisory-counts pattern, dim 9]; (4) `targetsLine()` in catchup/pipeline.go:122-124 swallows GetTargetCounts error without a log — inconsistent with the F5 logging just added in the same file [minor, dim 9]; (5) N1 DigestQueries bulk `markRead` lacks the `read_at` column guard its siblings have [internal-consistency nit, forward-only schema makes it harmless, dim 8].
- false-positive (this pass): badge over-count (raw unread without max_age) — confirmed pre-existing cheap-badge choice, not a regression. [6 AC]
- weak-dimension: still 7 (test quality) on the inherent items — truncation over-promise and the SidebarCounts internal try? fallbacks remain unexercised by the green suite, but neither is a correctness blocker.
- outcome: TBD until the --outcome step records the real merge result.
