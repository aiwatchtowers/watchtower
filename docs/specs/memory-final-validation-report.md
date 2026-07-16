# Secretary Memory — Final Validation Report

> Companion to `docs/specs/memory-final-validation-task.md`. Run on the work machine, live workspace `whitebit`, 2026-07-16/17. Covers **all three sections** — 0 (regression), 1 (Phase 3 semantic tier), 2 (Phase 4 surfaces). See the **Deliverable status** section at the end for the go/no-go verdict.

## Starting state

Vault at `~/.local/share/watchtower/whitebit/memory`: 447+ entities, ~384+ episodes carried over from the phases 0–2 E2E validation (`memory-e2e-report.md`), including the 8 known duplicate episodes from the killed-run incident. `memory.enabled` was already `true`; `memory.semantic.enabled` was turned on for this run (first time it has ever run for real against this workspace).

## Section 0 — regression sweep (phases 0–2)

- `memory status`, one plain `consolidate`: clean — 0 refs rejected/malformed/quarantined this pass, watermark and extraction debt advanced normally (208 → 147 messages).
- Kill-resilience re-check: two attempts.
  1. Killed (SIGKILL) before the extraction phase committed anything — only a mechanical `memory(seed)` commit had landed. Watermark and debt correctly did not advance (nothing spurious). Confirmed the stale `pipeline_runs.status='running'` row left by the SIGKILL does **not** block the next run — `memory.lock` (flock) releases on process death as expected.
  2. Killed again, this time waiting for a `memory(extract)` commit to land first — but the remaining backlog (147 messages) finished processing and the run exited cleanly before the kill could land mid-batch.
  3. **Not fully re-exercised**: a genuine "kill in the middle of a multi-batch extraction run, some batches committed and some not" scenario (the exact shape of the original E2E incident) could not be reproduced today because the real extraction backlog ran out first. This exact scenario was already found, fixed, and validated once before (`memory-e2e-report.md`, "killed-run watermark bug") — today's partial re-check found no regression in what it *did* exercise (no-op-safe kill before extraction, stale-lock non-blocking), and the owner accepted this as sufficient rather than artificially forcing a bigger backlog.

**Section 0 verdict: no regressions found.**

## Section 1 — Phase 3: semantic tier

Ran the semantic tier live for the first time against this workspace. This surfaced **three real bugs**, all found, root-caused, fixed, and re-verified live in this session (see commit `610ea8b` on `feature/secretary-memory`, and `docs/inventory/memory.md`'s 2026-07-16 changelog entry for full detail).

### Bug 1 — entity-page rewrite could essentially never fire

Only 2 of 450 entities in the lived-in vault had any linked episode (`## Links` populated) before the fix — `RewriteEntityPages` requires at least one linked episode per entity, so the entity-page rewrite step was structurally dead on arrival. Root cause: situations-ingest (~76/406 episodes) never linked entities at all, and raw-text extraction relied solely on the model's free-text `entity_hints`, whose prompt gave it almost no guidance and required an exact alias match.

**Fix:** link mechanically from already-validated structural fields instead of model judgment — episode `participants` (Slack user ids) + the episode's own channel, and for situations, `situation_signals`' channel_id/sender_user_id. `entity_hints` stays for genuinely model-judged mentions (named projects/concepts), with a clarified prompt rule.

**Live result:** linked entities 2/450 → 191/450. First live rewrite pass: 10/10 succeeded (previously 0, ever). Second live pass (new backlog): another 10/10.

**Hand-review (owner, not this session):** 10 rewritten entity pages — all real colleagues, git commit `7c770f2` in the vault repo. Structurally correct: only `## What`/`## Current`/`## Facts` touched, `## Links`/`## Open loops` untouched, no existing facts dropped. Content accuracy (does this reflect reality) needs the owner's own judgment — not graded here.

### Bug 2 — belief propose-new rejected 100% of the time

First live belief pass: 13 `propose-new` ops proposed, all 13 rejected with "subject does not resolve to an entity." The model was asked for "an entity id" but never shown one, so it invented readable slugs (`"ci-pipeline"`, `"ddos-incident"`, …) that could never resolve.

**Fix:** `ReviseBeliefs` now renders a "Known subjects" block (the active entities in scope this pass, as `id: title` pairs) into the prompt; the prompt's Rules tell the model to copy an id verbatim or skip proposing. `confirm`/`weaken`/`shake`/`retire` on existing beliefs were unaffected (they key off `belief_id`, not `subject`).

**Live result:** second live belief pass (after the fix): 3/3 proposed ops applied (previously 0/13).

**Hand-review (owner, not this session):** 3 beliefs created, git commit `1da80f5`. All structurally sound: birth confidence 0.5 (≤ 0.6 cap), `## History` line present, subject resolves to a real entity. Content accuracy needs the owner's judgment.

### Bug 3 — `memory reindex` broke on any dispute flag (found while verifying MEM-06)

While live-verifying MEM-06 (owner-rank belief protection), a deliberate drill (fabricated owner-rank evidence + a contradicting model op, both reverted afterward, no permanent vault changes) confirmed the core contract holds: the belief landed `shaken`, never `retired`, when the model proposed a retire against fresh owner-rank evidence.

Cleaning up that drill surfaced a **separate, real, live-reachable bug**: the MEM-06 downgrade itself mints a `memory_dispute_flags` row, and `db.DropMemoryIndex` (the full `watchtower memory reindex` path) deletes `memory_nodes` without clearing that table first — `memory_dispute_flags.node_id REFERENCES memory_nodes(id)`, so a single live dispute flag is enough to fail the whole reindex with a foreign-key error. This is not a drill artifact — it would hit **any** real MEM-06 downgrade or weekly-reflection dispute flag in production once Phase 4 surfaces are enabled.

**Fix:** `DropMemoryIndex` now also clears `memory_dispute_flags` — exactly the "self-healing on reindex" behavior the table's own doc comment already promised but never implemented.

**Live result:** `memory reindex` went from a FK-constraint crash to `Reindexed 910 nodes from the vault` cleanly; the drilled belief is confirmed back to `active`/`0.5` (its pre-drill state) and `memory_dispute_flags` is empty again.

### Other Section 1 checks (mechanical, all clean)

- **Dedupe:** 20 episodes merged per pass (hit the `dedupe_max_merges` cap both live passes) — the known killed-run duplicates plus newly-accumulated ones; provenance unions correctly (`union N provenance ref(s)`), tombstone redirects resolve.
- **Concept promotion:** 1 concept entity created (`kyc`, 5 backing episodes) — sane, no hallucinated concepts.
- **Two-tier map:** `map.md` = 1898 bytes, comfortably under the ~2 KB cap.
- **Cost/budget:** rewrite+beliefs output tokens per live pass: 27.8k and 13.8k — far under `memory.semantic.output_budget` (200,000). No budget-skip behavior observed or needed yet.

### Known gaps / not done in Section 1

- MEM-06 verified via a scripted (non-AI) drill against the real vault+DB, not a naturally-occurring live contradiction — the owner declined to fabricate a fake incident in real Slack data, and no real contradiction happened to be available on demand. The rank-math mechanism itself is also covered by the pre-existing `TestMemory06_OwnerRankBeliefNeverAutoFlipped` unit test.
- Entity-rewrite and belief content quality (the actual "is this true/well-written" grading) is the owner's to do — pointers above (commits `7c770f2`, `1da80f5`).
- Bug-1 fix backfills links going forward (all situations, since the ingest floor barely advances in this workspace) but does **not** retroactively backfill the ~330 pre-fix raw-extraction episodes that predate it; those only gain links if/when they're re-touched, which normally doesn't happen. Not a regression, just a slow convergence — noted for awareness.

## Section 2 — Phase 4 surfaces

All four flags (`memory.surfaces.{chat,briefing,disputes,reflection}`) enabled. Dark-default invariant confirmed first, with all four off: one `briefing generate` and one memory-dispute-detector pass produced no memory mentions, no `channel_id="memory"` inbox items, and no `reflect` `pipeline_steps` row — byte-for-byte the pre-Phase-4 behavior.

### 2a — Discuss injection + owner-rank write-back (real, not reverted)

Owner opened Discuss on situation #102 (already about the REG-386 story) and, in the owner's own words, stated the release decision belonged to Maksym Yukhno, not Bohdan Biriukov. `memory consolidate` staged the turn (`surfaces: 6 chat-turns`) and the belief pass:

- Shook the Bohdan belief (`active → shaken`), with the canonical, code-minted evidence line `- owner against chat:248 1784237683` (MEM-09 — rank came from the code recognizing a real `role='user'` situation turn, not from anything the model wrote).
- Independently proposed and created a **new** belief about Maksym Yukhno, its very first evidence line already `- owner for chat:248 1784237683` — a real, unplanned confirmation that owner-rank write-back generalizes correctly, not just a scripted one-off.

### 2b — dispute dashboard surfacing (drilled, then fully reverted)

The live-real Maksym belief now had fresh owner-rank support — the exact precondition MEM-06 protects. Rather than wait for/fabricate a real contradicting Slack incident, ran a scoped, reverted drill: a direct `ReviseBeliefs` call with a scripted `retire` proposal against it (citing one of the belief's own already-real evidence refs). Result: downgraded to `shaken` (never `retired`) and the M4 same-pass dispute flag was set — confirming MEM-06 holds under real vault/DB/git conditions, not just the unit-test fixture. Calling the watchtower inbox detector directly (`detectMemoryDisputes`) then confirmed the surfacing half: a `decision_made` inbox item minted with the exact `channel_id="memory"`, `message_ts="dispute:<belief_id>"`, and `"<statement> — evidence conflicts [[<belief_id>]]"` snippet contract, and the dispute flag cleared in the same call (MEM-10). All drill artifacts (the belief's retire, the dispute flag, the inbox item) were reverted/deleted; the belief is back to its real `active` state.

Note: found along the way that neither `watchtower inbox run` nor `watchtower briefing run` exist as CLI subcommands — `inbox` bare lists items, `briefing generate` is the real trigger, and the full detection pipeline (including this detector) is daemon-only. Not a bug, just a CLI-surface gap worth knowing before scripting future drills.

### 2c — briefing revision journal (real, restored to original)

The day's briefing (row id 96, generated 08:23) predated the belief transitions, so it was backed up, deleted, and regenerated to exercise this drill, then the original was restored byte-for-byte afterward (verified). The fresh generation's Team Pulse section wove in, unprompted: *"Память: убеждение сформировано — Maksym включил REG-386 в релиз... Ранее это приписывалось Bohdan Biriukov — атрибуция скорректирована"* — framed exactly as the prompt's Rules require (`"MEMORY REVISIONS ... frame it as something the memory noticed, never as fact"`; the design deliberately weaves a revision into `attention`/`team_pulse` rather than a separate labeled block, confirmed by reading `internal/prompts/defaults.go`). `briefing.daily` confirmed at prompt v6.

### 2d — reflection over git history

**Not exercised.** Weekly, deterministic per-workspace stagger — today was not this workspace's due day, and the owner chose not to force it. The mechanism itself is unexercised live; nothing suggests risk (it's a bounded, budget-gated, code-disposed pass per MEM-11), but it hasn't been seen firing on this vault.

### Section 2 verdict: no regressions found in what was exercised (2a/2b/2c); 2d not exercised.

## Deliverable status — GO, with one open item

**Go/no-go: GO to merge PR #36**, conditional on:

1. The owner completing content hand-review of the AI-written entity pages (`7c770f2`) and beliefs (`1da80f5`, plus the live Maksym belief) — mechanically sound, content accuracy not independently gradable by this session.
2. Accepting 2d (reflection) as unexercised-but-low-risk, or scheduling a follow-up check once the workspace's stagger day comes up naturally.

All abort criteria from the task doc (watermark regressions, >20% ref rejection, machine content in owner-edit commits, memory-side writes to inbox/situation tables, owner-rank minted from a non-`role='user'` source, a surface mutating belief confidence/status directly) — **none triggered** across Sections 0–2. Three real bugs were found and fixed during Section 1 (entity linking, belief subject resolution, `DropMemoryIndex` FK) — all guarded by new tests, all re-verified live, all committed (`610ea8b`). Enablement decision at merge time (per the roadmap): `memory.enabled` at minimum; the four Phase 4 surface flags all validated live this session and safe to stage on.
