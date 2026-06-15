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
