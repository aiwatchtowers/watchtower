# TASK: Full-feature validation on the work machine (phases 0–4)

> **Living document** — each phase appends its section as it lands on `feature/secretary-memory`. The owner runs this ONCE, when the whole memory feature is implemented, as the last gate before PR #36 leaves draft. Run on the work machine (live workspace `whitebit`).
> Protocol: `docs/specs/memory-autonomy-protocol.md`. Prior art: `docs/specs/memory-e2e-report.md` (phases 0–2 already validated 2026-07-16 — those checks are NOT repeated here except where later phases could regress them).

## Setup

```
git fetch && git checkout feature/secretary-memory && git pull
make build
./watchtower config set memory.enabled true
./watchtower config set memory.semantic.enabled true      # phase 3 (dark by default)
# phase 4 flags: memory.surfaces.{chat,briefing,disputes,reflection} — all default false, enabled per-drill in Section 2
# phase 5 slice-1 flags: memory.sources.{gmail,actions} — both default false, enabled per-drill in Section 3
```

The vault at `~/.local/share/watchtower/whitebit/memory/` already contains the phases 0–2 E2E data (447+ entities, ~384+ episodes incl. 8 known duplicate episodes from the killed-run incident, one manually-set watermark) — this is deliberately the starting state: phase 3 must cope with a lived-in vault, not a fresh one.

## Section 0 — regression sweep (phases 0–2, quick)

1. `./watchtower memory status` — sane counts, watermark present, debt reflects days since the E2E.
2. One `consolidate` (the mandatory `--once` flag was dropped — a plain invocation runs one pass) — stats line clean (no unexpected quarantine/malformed spikes), watermark advances.
3. Kill-resilience re-check (the E2E blocker's fix — root cause was window ordering suppressing per-batch watermark advances, fixed by first-ts ordering): note the watermark, start a pass, kill it mid-run (Ctrl-C / kill PID), run `memory status` then another pass — expect: the watermark reflects every batch that committed before the kill (per-batch durable advance), and the re-run duplicates AT MOST the in-flight batch's content, never earlier committed batches. This re-runs the exact incident from the E2E report.

## Section 1 — Phase 3: semantic tier

Enable the tier (`./watchtower config set memory.semantic.enabled true`) and run **two** passes: `./watchtower memory consolidate` (the mandatory `--once` flag was dropped — a plain invocation runs one pass). Each pass' run-done log line ends with `semantic: N deduped, N promoted, N rewritten, N belief-ops, N evicted`, and `pipeline_steps` for the run carries one row per semantic step after the extraction rows, `channel_name` ∈ {`dedupe`, `promote`, `rewrite`, `beliefs`, `evict`} (`status='error'` on an isolated step failure never fails the run). Config caps in play: `memory.semantic.{dedupe_max_merges=20, concept_min_episodes=5, concept_max_create=10, rewrite_max_entities=10, beliefs_max=20, evict_after_days=45, evict_max=50, output_budget=200000}`.

1. **Dedupe** (MEM-07): the 8 known duplicate episodes from the killed-run incident should merge (up to `dedupe_max_merges` per pass). Check the `dedupe` step row and the "N deduped" count; pick a merged pair and confirm `./watchtower memory open <newer-ep-id>` resolves (redirects) to the older winner, the winner's `## Provenance` carries the union of both refs (no ref lost), and `merged from [[…]]` is present. Record before/after episode + tombstone counts (`memory status`).
2. **Concept entities**: recurring extractor hints ("HSM", "phishing", …) promoted after ≥ `concept_min_episodes` (5) distinct-episode recurrences, ≤ `concept_max_create` (10) per pass. Check `./watchtower memory recall HSM` → concept page exists with the episodes back-linked; eyeball 5 for sanity (mechanical promotion only — no hallucinated concepts). Note that promotion progress in `memory_entity_hints` survives `memory reindex` (excluded from MEM-02).
3. **Entity-page rewrites** (hand review, the important part; capped at `rewrite_max_entities`=10 per pass, staggered ~1/entity/7 days so it takes several passes to cover the vault): pick 10 rewritten entities; grade each `## What`/`## Current`/`## Facts` good/usable/garbage; confirm `## Links`/`## Open loops` are untouched and existing owner facts survived; spot-check 3 `Provenance:` markers per page resolve to real messages (MEM-01/MEM-08 — markers not in the input set are dropped, never invented).
4. **Beliefs** (hand review; ≤ `beliefs_max`=20 ops/pass): read the `bel_*` beliefs created (`memory recall`/`memory open`). For 10 random ones: is the statement falsifiable and grounded in the cited `## Evidence`? Birth confidence ≤ 0.6, `## History` line present. Any belief that misreads its evidence = record verbatim (anonymized). Check MEM-06: hand-add a contradicting note to an owner-rank belief via an owner edit, run a pass, verify the belief is `shaken`, never `retired`/flipped (the model op is downgraded by the rank math).
5. **Two-tier map**: `map.md` ≤ ~2 KB (`wc -c map.md`; hard-capped code-side) and reads as "what's going on"; `./watchtower memory index` prints the full `index.md` listing; MCP `memory_map` returns the hot `map.md`. Toggle `memory.semantic.enabled false` and confirm `map.md` is still produced mechanically (fallback) so `memory_map` never loses its target.
6. **Cost / budget**: sum the `output_tokens` of the `rewrite`/`beliefs` `pipeline_steps` rows across a pass and compare to `memory.semantic.output_budget` (200000); extrapolate daily. Verify the budget guard: on a pass whose accumulated output tokens exceed the budget, the later strong-tier AI steps (rewrite/beliefs/strong map) are skipped and logged (no `rewrite`/`beliefs` step rows for that pass), while the mechanical dedupe/promote/evict steps still run.

## Section 2 — Phase 4: surfaces

The four surfaces are dark by default, each behind its own gate. Enable them explicitly (they have independent blast radii — turn on only what a step exercises, so a regression is attributable):

```
./watchtower config set memory.surfaces.chat true
./watchtower config set memory.surfaces.briefing true
./watchtower config set memory.surfaces.disputes true
./watchtower config set memory.surfaces.reflection true
```

With all four off, first confirm the **dark-default invariant**: one `consolidate` + one `briefing` + one inbox cycle produce byte-for-byte what phases 0–3 did (no MEMORY block in the Discuss prompt, no *Memory revisions* section content, no `channel_id="memory"` inbox items, no `reflect` `pipeline_steps` row). Then run the drills below.

### 2a — Discuss injection + owner-rank write-back (the staged disagreement)

The load-bearing round-trip. Pick an existing active belief with a clear subject entity (`./watchtower memory recall …`), e.g. *"Alice owns the deploy pipeline"*.

1. **Injection (`memory.surfaces.chat`).** Open the Desktop app, open a situation whose channel/members alias that subject entity, and open its **Discuss** chat. Confirm the system prompt now carries a MEMORY block **between the owner brief and the TOOLS block**, labeled "notes the secretary has built from Slack/Jira — model-mediated, not the owner's own words": the hot `map.md` (≤4 KB, truncated at a line boundary), the relevant entities, and active/shaken beliefs rendered as `statement (confidence, status)` — a `shaken` belief must carry the `(uncertain — evidence conflicts)` marker. The TOOLS line must advertise `memory_recall` / `memory_open` / `memory_map`. With `memory.surfaces.chat false` the block is **absent** (prompt byte-identical to pre-Phase-4).
2. **Owner-rank write-back (MEM-09).** In Discuss, tell the secretary something that contradicts the belief in the owner's own words, e.g. *"Actually Bob has owned the deploy pipeline since last month, not Alice."* Then run one `./watchtower memory consolidate` (with `memory.semantic.enabled true`). Expect: `ingestChatStatements` stages the `role='user'` turn (run-done log `surfaces: N chat-turns`); the belief pass cites it and the code mints a canonical `- owner against chat:<conversation_id> <ts>` line in the belief's `## Evidence` (open the belief: `./watchtower memory open <bel-id>`). Verify the elevation is **authored, not claimed**: the model op carried no rank; only the `chat:` ref resolving to a `role='user'` situation turn made it owner rank. A turn that is an assistant reply, or in a non-situation chat, must NOT mint owner rank.
3. **Belief updates per rank math.** The freshly-added owner-`against` line, with no fresh owner support remaining, should let the belief shake or (once owner support has decayed) retire per the Phase-3 math — never a direct write. Record the belief's `## History` line and its new status/confidence.

### 2b — The reverse: a dispute situation on the dashboard (MEM-05/10)

Now force the *arguing secretary*. Take a belief the owner asserted (owner-rank support, still fresh) and let observation contradict it. The dispute now fires **promptly from the belief pass itself** (M4): hand-add a contradicting episode/owner-note so the model proposes a retire/flip, run one `./watchtower memory consolidate` — MEM-06 owner-rank protection downgrades the op to `shaken` AND `applyExistingOp` sets a `memory_dispute_flags` row in the same pass (no need to wait a week for reflection; reflection at 2d remains a second, slower path for *flapping* beliefs). Then with `memory.surfaces.disputes true`, run one inbox cycle (`./watchtower inbox run` or the daemon):

- A `decision_made` inbox item appears with `channel_id="memory"`, `message_ts="dispute:<belief_id>"`, snippet = the belief statement + " — evidence conflicts [[<belief_id>]]".
- The `memory_dispute_flags` row for that belief is **cleared in the same cycle** (a second inbox cycle mints no duplicate — dedup + one-shot clear). Dedup keys on LIVE items only (M2): once you archive or resolve the dispute item and the belief is re-flagged, the next inbox cycle surfaces the dispute again (the dead row is revived in place); a still-open dispute item blocks a duplicate.
- Triage/compose fold it into a dashboard **situation** (DASH-01), shown with the secretary card; the `[[<belief_id>]]` vault link resolves via `memory_open`. Confirm INBOX-01 held (the item was never dropped, only possibly downgraded) and the inbox watermark advanced normally (INBOX-09) — this is an ordinary detector item.
- **MEM-10 spot check:** the memory pipeline itself wrote no `inbox_items`/`situations` row — only the flag; the inbox detector minted the item. (`grep -rn "inbox_\|situations" internal/memory/` shows reads only.)

### 2c — Briefing revision journal (`memory.surfaces.briefing`)

After 2a/2b moved a belief, generate the next morning's briefing (`./watchtower briefing run` for the owner). Expect a *Memory revisions* line naming the belief and what changed — `<belief title> — <what changed> — because <evidence digest>`, framed as a memory note derived from Slack/Jira, never "you said." A sub-0.2 confidence wiggle produces **no** line (notability filter: status transitions and ≥0.2 confidence moves only). With `memory.surfaces.briefing false`, or on a day nothing notable changed, the section renders the sentinel `(no notable revisions)` and the briefing must not mention memory at all. Confirm `briefing.daily` is at prompt **v6** (`./watchtower prompts show briefing.daily`).

### 2d — Reflection over git history (`memory.surfaces.reflection`)

Reflection is a **weekly** strong-tier pass on a deterministic per-workspace stagger — it fires on at most one day per 7, so a single consolidate on the wrong day is a clean no-op (no `reflect` `pipeline_steps` row content beyond a skip, no AI call). To exercise it on demand, either run on the workspace's due day or temporarily confirm the stagger by reading the run's `reflect` step. On a due pass over a lived-in vault:

- The run-done log ends with `surfaces: … N reflections (M disputes flagged)`; a `reflect` `pipeline_steps` row is present after `evict` (`status='skipped'` when the output budget was already spent — shares `memory.semantic.output_budget`).
- Confirm the two dispositions are **applied by code, not the model** (MEM-11): a flapping belief (≥3 in-window revisions) gets a `memory_dispute_flags` row — its confidence/status/stability **unchanged** (reflection never mutates belief math); a flapping entity gets a dated bullet appended to its `## Current` section as an ordinary `memory(reflect)` commit (`git -C …/memory log --oneline | grep reflect`). At most 3 observations per pass; an observation naming a node not in the churn set, or below the flapping threshold, is dropped.
- Sanity-grade the weekly note: does it name genuinely unstable areas, or invent instability? Record any garbage verbatim (anonymized).

Abort criteria (in addition to Section 0/1): any memory-side write to an inbox table, any owner-rank line minted from a non-`role='user'` source, or any surface mutating a belief's confidence/status directly — stop and report (these break MEM-09/10/11).

## Section 3 — Phase 5 slice 1: universal substrate (registry + Gmail source + interaction ingest)

Both sources default false. First confirm the **dark-default invariant**: with `memory.sources.gmail` and `memory.sources.actions` both false, one `consolidate` is byte-identical to pre-Slice-1 behavior — no Gmail work, no interaction ingest, and all THREE watermarks (`gmail_last_internal_date`, `memory_last_extracted_ts`, `memory_gmail_last_extracted_ts`) plus the interaction floor (`memory_last_interaction_id`) unmoved. Then run the drills.

Prereq: Gmail sync must have populated `gmail_messages` (`./watchtower gmail sync` on a Gmail-connected workspace). Requires the `feature/gmail-source` work merged.

### 3a — Gmail threads → episodes with working `mail:` provenance (`memory.sources.gmail`)

1. `./watchtower config set memory.sources.gmail true`, then `./watchtower memory consolidate`. Expect the run-done log's Gmail counters to move (`GmailEpisodes` > 0, `GmailThreadsFailed` low) and `memory_gmail_last_extracted_ts` to advance — **without** touching the Slack extraction watermark or the Gmail *sync* watermark (three independent watermarks, resolved ambiguity #7).
2. Hand-review a handful of new episodes (`./watchtower memory recall …` / `memory open <ep-id>`): a thread became **one** episode (participants, subject-as-title-ish, one story arc); each provenance ref is `mail:<message_id>`, and it **resolves** — the `mail:` resolver confirms a real `gmail_messages` row (a fabricated `mail:` id would have been dropped at write, MEM-01/MEM-12). Grade extraction quality; record any thread that split into many episodes or fabricated participants.
3. **Sender stitching check.** Confirm distinct external `from_email` senders became **person entities** aliased by their email (`memory recall <sender name>`). An email that already aliased a seeded Slack person (same address on the `users` row) must be **stitched** — no duplicate entity — while a genuinely external sender is a new entity. Spot-check one of each: `memory open <ent-id>` shows the email in the aliases; `grep` the index for the address returns exactly one node.

### 3b — Owner-action drill: interactions → annotations + engagement (`memory.sources.actions`)

1. `./watchtower config set memory.sources.actions true`. In the Desktop dashboard, act on a live situation whose channel/members alias a known entity: **dismiss** one situation and **convert** another to a Target. Also 👎 one signal. Then `./watchtower memory consolidate`.
2. **Episode-mirror annotation.** Open each acted-on situation's mirror (`memory recall`/`open` by its `situation:<id>` alias): its `## Outcome` gained a dated owner-action bullet — `owner dismissed` for the dismissal, `converted to target #N` for the conversion, `owner dismissed` for the 👎 (distinct from IngestSituations's status-derived Outcome — this records the OWNER'S action). Re-run `consolidate` once: the bullet is **not** duplicated and (verdict path) engagement is **not** double-counted — the re-scan is idempotent.
3. **Engagement aggregate moved.** Confirm the subject entity's `memory_engagement` row moved: `sqlite3 …/watchtower.db "SELECT * FROM memory_engagement WHERE node_id='<ent-id>'"` — `engaged_count` up for the conversion, `dismissed_count` up for the dismissal/👎. The interaction floor (`memory_last_interaction_id`) advanced past the folded `inbox_feedback` rows.
4. **Owner-action rank, no MEM-06 protection (MEM-15).** Take a belief on the dismissed situation's subject entity, stage its `act:` ref into the belief pass (it is staged automatically when actions is on), and confirm: a validated `act:<table>:<row_id>` mints a canonical `- owner-action …` evidence line (weight 0.8), the model never named the rank (op JSON has no rank field), and — decisively — that owner-action line does **NOT** protect the belief from retirement (`hasFreshOwnerSupport` keys on `rankOwner` only). An `act:` ref to a non-existent/non-whitelisted row is dropped like an invented ref.
5. **Retention consumes engagement.** Confirm an engaged entity's cold episode resists eviction while an otherwise-identical un-engaged twin evicts: find (or age) a cold closed episode linked from an engaged entity and one linked from an un-engaged entity, run `consolidate`, and confirm only the un-engaged one rolled into a `sum_*` rollup. The engagement bonus is the deciding factor (`RetentionInputs.Engagement`).

### 3c — Substrate invariants (MEM-05 + MEM-12)

- **MEM-05:** with both sources on, the Gmail extractor and interaction ingest wrote **no** `inbox_items`/`situations`/`situation_signals`/`inbox_feedback` row and never moved `inbox_last_processed_ts` (`grep -rn "inbox_\|situations" internal/memory/` shows reads only; dump the tables before/after a `consolidate` and diff).
- **MEM-12:** inject a provenance ref of a bogus scheme (e.g. hand-edit a test extractor reply, or reason from the guard test) and confirm it is **rejected at write, counted, never written** — only the four registered schemes (`""`/`chat`/`mail`/`act`) resolve.

Abort criteria (in addition to Sections 0–2): any memory-side write to an inbox table from the Gmail or interaction step, an `owner-action` line minted from anything but a validated whitelisted interaction row, an `owner-action` line conferring MEM-06 protection, or either source doing work while its gate is off — stop and report (these break MEM-05/12/15).

## Deliverable

`docs/specs/memory-final-validation-report.md` on this branch: per-section results, hand-review grades with anonymized examples (never raw message text), cost table, and the go/no-go verdict for merging PR #36 to main. Abort criteria from the E2E task still apply (watermark regressions, >20% ref rejection, machine content in owner-edit commits — stop and report).
