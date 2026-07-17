# Secretary Memory — Final Validation Report

> Companion to `docs/specs/memory-final-validation-task.md`. Run on the work machine, live workspace `whitebit`, 2026-07-16/17. Covers Sections 0–2 (2026-07-16 session, phases 0–4) and **Sections 3–6** (2026-07-17 autonomous session, Phase 5 slices 1–4, branch `feature/memory-phase5`, binary v0.5.0-562-g9a8e5fb). See the **Deliverable status** sections at the end for the go/no-go verdicts.

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

---

# Sections 3–6 — Phase 5 slices 1–4 (2026-07-17, autonomous session)

## Session setup and constraints

- Branch `feature/memory-phase5` at `9a8e5fb`, fresh `make build`. Daemon stopped for the session (restarted after); DB backed up first (`watchtower.db.backup-20260717-final-validation`).
- **Owner-action drills were NOT simulated.** Fabricating owner actions (👎 feedback, situation dismiss/convert, Discuss turns) would mint owner-rank / owner-action evidence from non-owner input — the exact class MEM-09/15 exist to prevent. Every drill that requires a genuine owner act is listed under **Deferred to owner** below; everything mechanical/AI-side was exercised live.
- **Migration gap found and repaired (FINDING M1):** the work-machine DB's goose `version_id=16` had been burned on 2026-07-14 by a transcriber-branch binary, so this branch's `00016_gmail_source` would silently never apply — `gmail_messages`/`gmail_auth_state` absent while goose reads v16 as applied. Hand-applied the migration's Up SQL (live `inbox_items` DDL verified byte-equivalent to the migration's expectation first); 00020–22 then auto-applied cleanly on first open. `memory reindex` (954 nodes) populated the new `memory_provenance` index (1170 message-scheme rows) — required for slice-3 window queries over a pre-existing vault, and exactly the documented MEM-02 rebuild path.
- `memory.semantic.enabled` was toggled off for the mechanical drills (actions / calendar / mirrors are semantic-independent by design) and restored after — keeps attribution clean, AI spend near zero.

## Dark-default invariant (checked once for all four sections)

With every phase-5 gate off (`memory.sources.{gmail,actions,calendar,chats,operational}`, `memory.renders.digest_compare`, `memory.surfaces.{day_plan,meeting_prep}`, `memory.semantic.preferences` — all absent from config = default false), one full `consolidate` (run 16481, semantic on):

- Run-done counters: `gmail: 0 episodes; calendar: 0 episodes; mirrors: 0 mirrored; interactions: 0 folded; compare: 0 shadowed`.
- Watermarks: gmail-extract 0→0, calendar 0→0, interaction floor 0→0, gmail-sync 0→0, chat-turn floor 199→199 (the one unscanned turn is an assistant reply — correctly not an owner turn); Slack extraction advanced normally (137 messages, ordinary phase-0–2 behavior).
- **Ten table dumps byte-identical** across the run: `inbox_items, situations, situation_signals, inbox_feedback, targets, tracks, day_plans, day_plan_items, digests, digest_topics`. No `memory_digest_shadow` / `memory_engagement` rows.
- Day-plan prompt captured gate-off (argv-shim on the `claude` subprocess, AI never invoked, no DB write): v3 template with `MEMORY OPEN LOOPS` carrying the sentinel `(no memory open loops)` + the rule-9 dedupe instruction. Meeting-prep gate-off: v4 template, `ATTENDEE MEMORY` = `(no memory context)`. Matches the F14-corrected contract (sentinel-bearing templates, not slice-3 bytes).

## Section 3 — slice 1 (registry + Gmail + interaction ingest)

- **3a Gmail: SKIPPED (prereq unavailable).** Gmail was never connected on this machine (`gmail login` is an interactive OAuth flow; `gmail status` → "not connected", `gmail_messages` empty). Gate-off invariant confirmed; extraction mechanics remain unit-test-covered only. Needs a Gmail-connected run before the source is enabled for real.
- **3b interaction ingest — verdict-path MECHANICS validated live; trigger classification found broken (FINDING M7).** The 14-day window held 19 terminal `done` situations; the one with a live episode mirror (situation 97) folded exactly as specified: `interactions: 1 folded (3 engagement bumps)`, the mirror's `## Outcome` gained a dated `- 2026-07-16: owner resolved` bullet (distinct from the status-derived Outcome line), the 3 subject entities got `memory_engagement.engaged_count=1` stamped with the interaction time, and an immediate re-run was **idempotent** (`0 folded`, one bullet, engagement unchanged). The interaction floor stayed 0 (correct — verdicts are floor-less; `inbox_feedback` is empty). A second fold (situation 128) landed identically mid-session when the daemon auto-resolved it.
  - **FINDING M7 (major, slice-1 defect, live-caught):** all 19 of those `done` verdicts turned out to be **system auto-resolves** (`resolved_reason='signals_resolved'`, minted by the inbox pipeline) — the owner never clicked anything. `ListInteractionSituations` filters on `status IN ('converted','dismissed','done')` only and ignores `resolved_reason`, so the interaction ingest annotated a system action as `owner resolved` and bumped owner-engagement for it. Once `memory.semantic.preferences` is on, system auto-resolve behavior would feed **preference beliefs about the owner** — an MEM-15-adjacent semantic leak (the `act:` machinery is supposed to carry *owner* interactions only). Both false annotations were reverted in the vault (git reverts `c4e4452`/`aa86a23`) and the contaminated `memory_engagement` rows deleted before ending the session. **Fix required before enabling `memory.sources.actions` for real:** filter on owner-authored reasons (`user_done`/`user_dismissed`; `converted` is always owner-initiated) — with a test seeding a `signals_resolved` situation that must NOT fold.
  - **FINDING M3 (coverage, pre-existing):** most terminal situations have no episode mirror (e.g. 52, 54, 58, 60, 65, 68, 70, 71, 74, 79, 83, 88, 116 lack `situation:` aliases), so their verdicts can never fold; `listIngestSituations` also excludes `dismissed` entirely. Phases-0–2 ingest coverage issue, not a slice-1 defect — but it caps how much owner signal the interaction ingest can ever see.
  - 👎 feedback path and the MEM-15 owner-action-evidence-in-a-belief live check: **deferred to owner**. Retention-consumes-engagement (3b.5): N/A — the vault is younger than `evict_after_days=45`; nothing cold enough to evict.
- **3c invariants.** MEM-05: the six inbox/operational dumps byte-identical across the actions runs, `inbox_last_processed_ts` unmoved, `grep` shows zero inbox-table writes in `internal/memory/`. MEM-12 (bogus-scheme rejection) via the green guard suite (`TestMemory*` in memory + db packages, all pass on this machine).

## Section 4 — slice 2 (calendar + chats generalization)

- **4a calendar: validated live on 54 real (stale, May) events.** Calendar OAuth is revoked (`invalid_grant`) so no fresh sync was possible — but `calendar_events` still held 54 ended May events (sync retention never ran), and the watermark-0 first pass ingested them all: `calendar: 54 episodes (0 events failed)`, watermark 0 → 1778198400 (2026-05-08, newest end), Slack/Gmail watermarks untouched — the fourth watermark is genuinely independent.
  - Hand-review: one ended event → exactly one episode; Story = the mechanical metadata line (date/time UTC, organizer, participants); the single provenance ref `cal:<event_id>` resolves; `memory_provenance` gained 54 `cal`-scheme rows.
  - Attendee identity stitching: attendee emails landed as aliases on the **existing Slack person entities** (e.g. one node carrying both `U07PMUPR6G1` and `ihor.ivanisenko@ec319.com`), each with `[[ep_…]]` back-links to the meeting episodes. No duplicate entities observed.
  - **`calseries` not exercisable (FINDING M5a):** the May-era sync (old binary) stored `raw_json='{}'`, so no `recurringEventId` exists to parse — 38 recurring events, 0 series entities. Data limitation; the seeding path stays unit-test-covered. Will self-heal on the first fresh sync.
  - Recap enrichment + late-recap refresh: drilled with a clearly-marked synthetic `meeting_recaps` row (deleted afterwards): the re-scan **refreshed the same node in place** (`calendar: 1 episodes`, same `ep_` id, Outcome gained the `- Decision:` bullet); deleting the recap and re-running self-reverted the episode to metadata-only. Idempotency: an unchanged re-run → `calendar: 0 episodes`, no calendar commit.
- **4b "remember this": deferred to owner** (typing Discuss turns = authoring owner statements). The context-type gating and MEM-09 extension remain covered by the green `TestMemory09_*` suite.
- **4c invariants.** MEM-05 held (table hashes unchanged across the calendar runs); MEM-09/12 via guard tests.

## Section 5 — slice 3 (digest render-inversion, dark compare)

- **Dark-default:** confirmed in the combined dark run (`compare: 0 shadowed`, no shadow rows, no report).
- **5a — the compare ran two ways:** as the `phaseMemory` tail sub-step inside a consolidate (run 16488: `compare: 54 shadowed (1 failed, 0 refs rejected)`) and via `watchtower memory digest-compare --since 168h` (CLI, remaining windows; the fresh-shadow short-circuit let the two split the work without double-spend). Final: **212 windows shadowed, 58 failed (transient claude-CLI `api_error` — counted, skipped, never written; a model-availability artifact of the day, not a code defect), 0 invented refs dropped.** Report written to `docs/specs/memory-digest-compare-report.md`.
- **Ref-validity, the headline number (report aggregate):** legacy `key_messages` ref-validity **0.2% (1/402)** — worse than the audit's ~0.6%; the hallucinated-ref class is endemic. Memory renders: **100.0% (751/751), `render_refs_rejected = 0` on every shadow row** — MEM-13 holds on live data by construction. Mean episode coverage **16%**; length ratio memory/legacy **0.98** (renders are not longer than legacy). Hand-spot-check: 29/29 render refs opened real messages.
- **5b — hand-review, 5 channels side by side** (legacy digest vs `memory_digest_shadow.rendered_json`):
  1. `wb-aaa-dev` (coverage 1.0): same story (PR CEX-7413 / trade_restriction_id in JWT), memory render richer (3 open questions + 2 assigned action items), 3/3 refs resolve. **≥ legacy.**
  2. `hashbank-nova-card` (coverage 0.67): same story (partner rate issue, fix promised), 3/3 refs. **≥ legacy.**
  3. `trade-integration` (coverage 0.50): same story (mobile balance display bug), memory adds the resolution + 2 decisions, 5/5 refs. **≥ legacy.**
  4. `wb-dev-cryptocard-project` (coverage 0.07): memory caught 3 of legacy's 4 topics — the missed one (mass doc-transfer production bug) is an **extraction-coverage gap** exactly as the task predicts (coverage metric explains it), 10/10 refs. **Quality-parity within coverage; coverage itself low.**
  5. `wb-convert-dev` (coverage 0.04): the one story legacy carried is present despite 4% coverage, 8/8 refs. **≥ legacy within coverage.**
- **5c — legacy untouched:** the dark-run dump byte-identity covered `digests`/`digest_topics`; during the daemon-down window when the compare ran solo (10:30–11:06 local), **zero** `digests` rows were written (the 5 new rows all post-date the daemon respawn); `grep` on `digest_compare.go` confirms reads only; the compare wrote only `memory_digest_shadow`. MEM-13 bogus-ref injection: pinned by `TestMemory13_RenderCitesOnlyEpisodeProvenance` (green); live injection not separately staged.
- **Go/no-go signal for the eventual legacy switch:** quality ≥ legacy wherever coverage is decent, and ref-validity is 100%-by-construction vs legacy's 0.2% — but **coverage is the gating metric** (mean 16% across the 212 windows: extraction lags the most recent windows, many low-traffic windows have no episode at all, and see M2/M3 ingest gaps). GO for continuing dark-mode accumulation; NOT yet a switch-grade coverage level. The full per-channel table is in `docs/specs/memory-digest-compare-report.md`.

## Section 6 — slice 4 (mirrors + read surfaces + preference beliefs)

- **Mirrors (`memory.sources.operational`).** First gates-on pass: `memory(mirror): 910 target/track mirror(s)` — one commit, zero failures, zero AI calls. Hand-review: `target:19` carries `## What` (text + level), `## Current` (Status/Priority/Next step), `## Open loops` = its open sub-items; `track:242` carries Category/Ownership in What, `Status/Priority/Ball on/Sub-items 0/5 done` in Current, all five sub-items as open loops. 
  - **VAULT-SIZE NOTE (FINDING M4):** tracks have no terminal state except `dismissed_at` (17 of 908), so 891 tracks mirrored — the vault roughly doubled (954 → ~1 870 nodes) in one pass, and the R2-F3 "every terminal row with a mirror pays a re-scan each run" deferred cost now applies to a ~900-row set from day one. By design, but the owner should know the vault is now majority-mirrors, and `index.md`/recall ranking now swim in track entities.
  - Conversion cross-link (`## Links` → originating `situation:` episode): **no converted situation exists in this DB** (the owner has never used the Target/Track convert buttons) — deferred to owner.
  - MEM-14: `targets`/`tracks`/`day_plans`/`day_plan_items` dumps were byte-identical from the session start through every pre-mirror run (10:28–10:56); the dump-equality check **across the mirror pass itself was confounded** by the Desktop app auto-respawning the daemon mid-pass (11:06) — the post-pass diffs are attributable daemon/Desktop writes (tracks-pipeline stamps, day-plan regeneration), and the memory-side no-write proof rests on `grep` (no operational-table write exists in `internal/memory/`) plus the green `TestMemory14_*` / `TestMirror*` guards (incl. the R1–R4 alias-set/GLOB regressions).
  - No-op re-run: `mirrors: 0 mirrored (0 failed)`, and **no mirror commit** in the vault delta (the delta's other commits — extract/ingest/interactions — belong to concurrent daemon-era activity; see the environmental note below). Content-equality keeps the 910-mirror steady state free.
  - **Environmental note:** the Desktop app auto-respawned the daemon at 11:06 (its bundled binary), resuming sync/inbox concurrently. The dark-default and MEM-05 byte-identity proofs all predate 11:06 and stand unconditionally.
- **Day plan (`memory.surfaces.day_plan`).** Gate-on prompt capture: `MEMORY OPEN LOOPS` filled with real track open loops that the TARGETS section does not carry, rule-9 dedupe instruction present; gate-off = sentinel; `day_plans`/`day_plan_items` untouched in both captures (the shim fails the AI call before any write — persist is after parse by design).
  - **FINDING M6 (fairness):** `maxMemoryOpenLoops=10` has no per-entity cap — a single bushy track (the SDET pipeline track, 10 sub-items) filled the entire block, starving every other entity/target loop. Recommend a per-entity cap (e.g. 3) before relying on this surface.
- **Meeting prep (`memory.surfaces.meeting_prep`).** Gate-on capture against a real May meeting with 12 attendees: `ATTENDEE MEMORY` renders per-attendee `What:` excerpts plus `## Facts` bullets (Saienko's 4 facts came through), model-mediated framing in the rules; an attendee with no entity degrades to `(no memory entity for this attendee)`; no cache/DB/vault write across the capture.
  - Cosmetic (FINDING M5b): the owner himself rendered as "(no memory entity …)" — his entity has no email alias yet (no Gmail source, and calendar stitching apparently skips self); three attendees with empty entity pages render a bare `### <email>` header with nothing under it (no absence line). Both cosmetic, no wrong data.
- **Preference beliefs (`memory.semantic.preferences`): deferred to owner-period observation.** Forming one requires several genuine dismissals sharing a subject across cycles; none exist in the window and fabricating them is exactly what MEM-15 guards against. The gate-off byte-identity and the mint/ghost-ref paths are pinned by `TestReviseBeliefsPromptByteIdenticalWhenPreferencesOff`, `TestPreferenceBeliefBornFromOwnerAction`, `TestPreferenceBeliefGhostActRefDropped` (all green).

## Findings (Sections 3–6)

| # | Severity | Finding | Recommendation |
|---|----------|---------|----------------|
| M7 | **major (slice-1 defect, live-caught)** | interaction ingest classifies system auto-resolves (`resolved_reason='signals_resolved'`) as owner verdicts — false `owner resolved` annotations + false owner-engagement; would feed 5D preference beliefs from system behavior | filter verdict re-scan on owner-authored `resolved_reason` (+ guard test); contamination reverted this session |
| M1 | major (infra, this machine) | goose v16 burned by a transcriber-branch binary → `00016_gmail_source` silently skipped; hand-repaired this session | before merge: schema-presence assertion on open, or renumber the gmail migration |
| M2 | **major (pre-existing, phases 0–3 interplay)** | composer attached one inbox signal to two situations (103+106) → dedupe merged their mirror episodes into one node → situations-ingest **ping-pongs the node every consolidate**: one commit per run forever, stories overwrite each other, the loser's provenance ref drops/reappears each flip | exclude nodes carrying `situation:` aliases from dedupe merge candidates (or key mirror identity on the alias); until then every consolidate mints a junk commit |
| M3 | medium (pre-existing) | most terminal situations have no episode mirror; `dismissed` never ingested → owner verdicts on them can never fold into memory | widen ingest coverage or accept capped owner-signal |
| M4 | medium (product question) | 891 non-terminal tracks mirrored on first pass — vault majority-mirrors overnight, R2-F3 rescan cost on ~900 rows | consider a staleness cut for auto-tracks (e.g. skip tracks with no update in N days and no open loops) |
| M5 | low | (a) `calseries` dead on stale `raw_json`; (b) meeting-prep bare header for empty entity pages; owner-self has no email alias | (a) self-heals on fresh sync; (b) emit the absence line for empty pages too |
| M6 | low | day-plan open-loops cap has no per-entity fairness — one track can starve the block | per-entity cap before the surface is relied on |

## Cost (Sections 3–6)

| Run | What | Output tokens |
|-----|------|---------------|
| 16481 (dark default, semantic on) | extraction 137 msgs + rewrite 10 pages + beliefs | ~38.9k (21k extract / 12.9k rewrite / 4.9k beliefs) |
| actions / calendar / mirrors runs (semantic off) | mechanical only | **0** |
| digest-compare | haiku-tier, one call per shadowed window (~190 windows this session, two runners) | not instrumented — the compare's `pipeline_steps` row records 0/0; telemetry gap worth a follow-up |

## Deferred to owner (blocking the remaining task-file checkboxes)

1. **OAuth: BLOCKED on this machine (owner, 2026-07-17)** — the owner currently cannot sign into mail/calendar here. `watchtower gmail login` (Section 3a has never run against real mail) and `watchtower calendar login` (token revoked; fresh events + recaps + `calseries` need it) stay open until access is possible. Both sources are dark by default, so this blocks only their own drills — not the merge and not the other deferred items.
2. **Desktop, ~5 minutes, with `memory.sources.actions` on:** 👎 one situation (bare, no comment), **dismiss** one situation that has a memory mirror, **convert** one situation to a Target — then run `watchtower memory consolidate` twice and check: `## Outcome` bullets (`owner dismissed` / `converted to target #N`), `memory_engagement` moves, the `## Links` conversion cross-link on the new target's mirror, and no duplication on the second run.
3. **Discuss drills (Section 4b + 2a-style):** with `memory.sources.chats` on — an ordinary drafting turn in a track chat (must be consumed-not-staged), a `remember this: <fact>` turn (must stage + mint owner evidence), an ordinary turn in a situation chat (still stages), then the same `remember this` with the flag off (must not scan).
4. **Preference beliefs (6.4):** with actions+semantic+preferences on, dismiss several situations sharing a subject over a few days, then verify a preference belief forms (confidence ≤0.6, real `act:` refs), appears in the briefing journal, and loses to an owner statement in Discuss.
5. Re-check the **M2 ping-pong** after its fix lands — it currently mints one junk commit per consolidate.

## Deliverable status (Sections 3–6) — conditional GO, two fixes and the owner drills outstanding

**Everything mechanical held.** No abort criterion triggered in what was exercised: no memory-side write to any inbox/operational table (MEM-05/14), no invented provenance survived a write anywhere (MEM-01/12/13 — 0 refs rejected at render across ~190 shadowed windows, 100% resolve on hand-check vs legacy's 0.3%), every gate-off path was byte-identical dark, all four new watermarks are independent, idempotency held on every re-run (interactions, calendar, mirrors), and the whole phase-5 guard suite is green on this machine.

**Blocking before `memory.sources.actions` is enabled for real:** the **M7** owner-verdict misclassification (system auto-resolves fold as owner actions — live-caught, contamination reverted). **Blocking before relying on consolidate hygiene:** the **M2** dedupe/ingest ping-pong (pre-existing, one junk commit per run). Neither blocks the merge itself — both are flag-gated or pre-existing — but M7 must land before the actions source (and therefore 5D preferences) goes live.

**Not exercised autonomously** (fabricating owner input would violate the very contracts under test): the 👎 feedback path, MEM-15 owner-action evidence in a live belief, "remember this" chat drills, preference-belief formation, conversion cross-links, plus Gmail (never connected) and fresh-calendar (token revoked) — all listed under *Deferred to owner* with exact steps. These are the remaining checkboxes between "conditional GO" and the task file's full completion.
