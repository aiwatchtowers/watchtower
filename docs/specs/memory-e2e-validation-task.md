# TASK: Phases 0–2 E2E validation on the work machine

> Branch: `feature/secretary-memory` (integration branch, PR #36 draft). Run on the **work machine** (live workspace `whitebit`, real message volume).
> Context: `docs/superpowers/specs/2026-07-15-secretary-memory-design.md` (what was built), `docs/inventory/memory.md` (contracts MEM-01..05 + known v1 limitations), `docs/specs/memory-data-audit.md` (the pre-build audit this validates against), `docs/superpowers/specs/2026-07-15-memory-phase3-semantic-tier-design.md` (draft whose knobs this run must produce).

## Goal

First run of the full consolidation pipeline on real data. Three questions, in priority order:

1. **Does it hold up?** Contracts under real volume: watermark discipline, provenance validation rates, quarantine behavior, lock vs a running daemon, idempotency.
2. **Is the output any good?** Human judgment on extracted episodes and the map — the only thing unit tests cannot answer.
3. **What are Phase 3's knobs?** Real numbers for the draft spec's deliberately unset parameters.

## Setup

```
git fetch && git checkout feature/secretary-memory && git pull
make build            # or go build -o watchtower .
./watchtower config set memory.enabled true
```

Notes:
- The daemon may keep running — the flock (`memory.lock`) is expected to make concurrent runs refuse cleanly; observing that IS one of the checks below.
- Everything is reversible: the vault is additive (`~/.local/share/watchtower/whitebit/memory/`), the SQLite index is rebuildable, and `config set memory.enabled false` turns it all off. No inbox/situation table is written by design (MEM-05).

## Run protocol

1. **Baseline**: `./watchtower memory status` (expect: 0 nodes, no watermark, debt = full backlog with `+`).
2. **First pass**: `./watchtower memory consolidate --once`. Record the printed stats line (seeded / ingested / episodes / windows / failed / refs_rejected / malformed / quarantined) and wall-clock time.
3. **Repeat** `consolidate --once` until extraction debt reaches 0 (each pass drains ≤ `memory.max_chunk_messages`=2000). Record the stats line of EVERY pass.
4. **Idempotency**: one more pass at zero debt — expect all-zero stats and no new vault commits (`git -C ~/.local/share/watchtower/whitebit/memory log --oneline | head`).
5. **Concurrency**: while a pass is running, start a second `consolidate --once` in another terminal — expect a clean "another memory run is in progress" refusal, no error artifacts.
6. **Owner edit round-trip (MEM-03)**: hand-edit one entity file (fix a What line), run a pass, verify a separate `memory(owner-edit)` commit precedes any machine commit and the edit survives in the file.
7. **Quarantine (F4)**: add a bogus frontmatter key to one node file, run a pass — expect quarantined=1 in output, pipeline continues, node's index row intact; revert the edit, next pass clean.
8. **Reindex**: `./watchtower memory reindex` — expect node count unchanged.
9. **Read surfaces**: `./watchtower memory recall <a topic you know was discussed>`, `memory open <alias>` (try a Slack channel ID and `situation:<id>`); if convenient, open the vault folder in Obsidian — links, aliases, graph.
10. Leave `memory.enabled` ON afterwards if the results look sane (the daemon then keeps consolidating in micro-chunks) — or OFF if anything looks wrong; note which.

## What to measure (→ report)

**A. Contract health (numbers from the stats lines + `pipeline_runs`/`pipeline_steps` where pipeline='memory'):**
- refs_rejected per pass (MEM-01 drop rate — the audit predicted near-zero for situations and honest ts from the extractor; a high rate means the prompt's copy-don't-invent instruction fails on this model tier).
- malformed count (shape-degenerate replies) and windows failed per pass; any window failing repeatedly = the poison-window story in practice.
- quarantined count on the untouched vault (expect 0).
- Watermark monotonicity: `memory status` watermark after each pass never decreases; debt strictly decreases.

**B. Cost & runtime (per pass, from pipeline_runs incl. the split cache columns):**
- input / output / cache tokens and wall-clock per pass; extrapolate steady-state daily cost at ~50K raw tokens/day (audit figure) — sanity-check against the audit's "cents per day" claim, measured **by output tokens**.

**C. Quality (hand review — the important part):**
- 10 random extracted episodes (`episodes/ep_*.md` NOT aliased `situation:*`): is the Story a real story? Is the Outcome right or empty-but-honest? Do provenance links open the right Slack messages (spot-check 2–3 each)? Grade each roughly good / usable / garbage.
- 5 situation-ingested episodes: faithful mirrors?
- 10 seeded entity pages: right people/channels? What-lines sensible? Any obvious missing entity (person you talk to daily with no page)?
- `map.md`: does the mechanical map read as a usable table of contents?
- 3 `memory_recall` queries you'd genuinely ask ("what happened with X") — did the right nodes surface?

**D. Phase 3 knob inputs (fill the draft spec's blanks):**
- Episodes per entity per week (from vault: links accumulated) → rewrite trigger N (draft default 5) and stagger period (draft 7d).
- Duplicate episodes observed (same story twice from retry/overlap)? How near are their titles → dedupe similarity threshold sanity.
- Episode age/volume distribution → eviction window (draft 45d) realism at this volume.
- Total vault size on disk + node counts after full drain → map-size discipline check (~2KB map still viable?).

## Deliverable

`docs/specs/memory-e2e-report.md` on this branch: the per-pass stats table, sections A–D with numbers, the episode-quality grades with 2–3 anonymized examples (no raw message text — same rule as the audit), a verdict per goal question (holds up / output quality / knobs), and an explicit list of anything that should block Phase 3 implementation. Push to `feature/secretary-memory`.

## Abort criteria

Stop and report immediately (don't push through) if: the watermark ever moves backwards; refs_rejected exceeds ~20% of refs on a pass (systemic hallucination — prompt problem); a pass crashes the daemon; or the vault git history shows machine content in an owner-edit commit. These are contract violations, not tuning issues.
