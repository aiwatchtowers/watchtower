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
