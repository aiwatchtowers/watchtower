# TASK: Full-feature validation on the work machine (phases 0–4)

> **Living document** — each phase appends its section as it lands on `feature/secretary-memory`. The owner runs this ONCE, when the whole memory feature is implemented, as the last gate before PR #36 leaves draft. Run on the work machine (live workspace `whitebit`).
> Protocol: `docs/specs/memory-autonomy-protocol.md`. Prior art: `docs/specs/memory-e2e-report.md` (phases 0–2 already validated 2026-07-16 — those checks are NOT repeated here except where later phases could regress them).

## Setup

```
git fetch && git checkout feature/secretary-memory && git pull
make build
./watchtower config set memory.enabled true
./watchtower config set memory.semantic.enabled true      # phase 3 (dark by default)
# phase 4 flag: added when phase 4 lands — see its section
```

The vault at `~/.local/share/watchtower/whitebit/memory/` already contains the phases 0–2 E2E data (447+ entities, ~384+ episodes incl. 8 known duplicate episodes from the killed-run incident, one manually-set watermark) — this is deliberately the starting state: phase 3 must cope with a lived-in vault, not a fresh one.

## Section 0 — regression sweep (phases 0–2, quick)

1. `./watchtower memory status` — sane counts, watermark present, debt reflects days since the E2E.
2. One `consolidate --once` — stats line clean (no unexpected quarantine/malformed spikes), watermark advances.
3. Kill-resilience re-check (the E2E blocker's fix — root cause was window ordering suppressing per-batch watermark advances, fixed by first-ts ordering): note the watermark, start a pass, kill it mid-run (Ctrl-C / kill PID), run `memory status` then another pass — expect: the watermark reflects every batch that committed before the kill (per-batch durable advance), and the re-run duplicates AT MOST the in-flight batch's content, never earlier committed batches. This re-runs the exact incident from the E2E report.

## Section 1 — Phase 3: semantic tier

*(To be finalized when phase 3 lands — checks below reflect the spec; adjust to what actually shipped.)*

1. **Dedupe**: after the first semantic-enabled pass, the 8 known duplicate episodes should be merged (check: `memory recall maildev` returns one episode, the merged-from links present, provenance union preserved — MEM-07). Record before/after episode counts.
2. **Concept entities**: recurring extractor hints ("HSM", "phishing", …) promoted to concept entities after ≥5 recurrences; check `memory recall HSM` → concept page exists, episodes back-linked. Record how many concepts appeared and eyeball 5 for sanity (no hallucinated concepts — mechanical promotion only).
3. **Entity-page rewrites** (hand review, the important part): pick 10 entities with the most episode links (people + channels + concepts mixed); grade each rewritten `## What`/`## Current`/`## Facts` good/usable/garbage; spot-check 3 provenance markers per page resolve to real messages (MEM-01 discipline in rewrites).
4. **Beliefs** (hand review): read ALL beliefs created (expected: dozens, capped per run). For each of 10 random ones: is the statement falsifiable and grounded in the cited evidence? Any belief that misreads its evidence = record verbatim (anonymized). Check hysteresis mechanics on one belief: hand-add a contradicting note via an owner edit, run a pass, verify shaken-not-flipped (MEM-06: owner-rank protection).
5. **Two-tier map**: `map.md` ≤ ~2 KB and genuinely reads as "what's going on"; `index.md` carries the full listing; MCP `memory_map` returns the hot map.
6. **Cost**: per-pass output tokens from `pipeline_runs` for the semantic steps vs the budget caps (`rewrite_max_entities_per_run`, `beliefs_max_per_run`); extrapolate daily.

## Section 2 — Phase 4: surfaces

*(To be written when phase 4 lands: Discuss injection + owner-rank writes round-trip, briefing revision-journal lines, dispute situations via the watchtower detector, reflection over git log. Will include: a staged disagreement — tell the secretary something in Discuss that contradicts an existing belief, verify owner-rank evidence lands and the belief updates; a briefing containing a revision line; one dispute situation appearing in the dashboard inbox with evidence links.)*

## Deliverable

`docs/specs/memory-final-validation-report.md` on this branch: per-section results, hand-review grades with anonymized examples (never raw message text), cost table, and the go/no-go verdict for merging PR #36 to main. Abort criteria from the E2E task still apply (watermark regressions, >20% ref rejection, machine content in owner-edit commits — stop and report).
