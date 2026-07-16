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
# phase 5 slice-2 flags: memory.sources.{calendar,chats} — both default false, enabled per-drill in Section 4
# phase 5 slice-3 flag: memory.renders.digest_compare — default false, enabled per-drill in Section 5
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

## Section 4 — Phase 5 slice 2: universal substrate (Calendar source + internal-dialogs generalization + "remember this")

Both sources default false. First confirm the **dark-default invariant**: with `memory.sources.calendar` and `memory.sources.chats` both false, one `consolidate` is byte-identical to post-Slice-1 behavior — no calendar work, no target/track chat ingest, the calendar watermark (`memory_calendar_last_extracted_ts`) unmoved, and the chat-turn floor advancing exactly as Phase-4 did (only `situation` turns scanned). Then run the drills.

Prereq: the calendar sync must have populated `calendar_events` (`./watchtower calendar sync` on a Calendar-connected workspace), and for the recap-enrichment check the meeting pipeline must have written a `meeting_recaps` row for at least one past event. The chat drills need the Desktop app to have created the Swift-owned chat tables (open any Discuss chat once) — on a headless daemon they are absent and the chat surface is a clean no-op.

### 4a — Calendar past events → episodes (`memory.sources.calendar`)

The load-bearing calendar check — the builder is **mechanical** (no AI call; the recap is reused, never re-synthesized). Because `calendar_events` retains only ~24 h of past events, run this **shortly after a real meeting window ends** so the event is still present.

1. Attend (or let end) a real calendar meeting, then `./watchtower config set memory.sources.calendar true` and `./watchtower memory consolidate`. Expect the run-done log's calendar counters to move (`CalendarEpisodes` > 0, `CalendarEventsFailed` low) and `memory_calendar_last_extracted_ts` to advance to the event's end unix — **without** touching the Slack/Gmail extraction watermarks or the Gmail *sync* watermark (a fourth, independent watermark).
2. Hand-review the new episode (`./watchtower memory open` via its `calevent:<event_id>` alias, or `memory recall <meeting title>`): one ended event became **one** episode; the Story carries the mechanical metadata line (date/time, organizer, participants, location, description); its single provenance ref is `cal:<event_id>` and it **resolves** — the `cal:` resolver confirms a real `calendar_events` row (a fabricated `cal:` id would have been dropped at write, MEM-01/MEM-12).
3. **Recap enrichment.** For an event that has a `meeting_recaps` row, confirm the recap's `summary` folded into Story and its `key_decisions`/`action_items`/`open_questions` into Outcome (`- Decision:` / `- Action:` / `- Open question:` bullets). An event with **no** recap must still be a real metadata-only episode. Grade whether the recap enrichment reads honestly (reused, not paraphrased/invented).
4. **Participants as person entities + series links.** Confirm each attendee resolved to a **person entity** (by Slack user id when the sync resolved one, else email alias) carrying a back-link `[[<ep-id>|…]]`. For a **recurring** meeting, confirm a `calseries:<recurringEventId>` series entity exists (`seedCalendarSeries`) and the instance episode links to it. A non-recurring event links no series.
5. **Idempotency + late recap.** Re-run `consolidate` with nothing changed: the episode is **not** rebuilt and **no empty git commit** lands (`git -C …/memory log --oneline` count unchanged). Then, if a recap lands *after* the first build but the event is still within the 2-day lookback, a re-run **refreshes the same episode node in place** (same id, Outcome now carries the recap) — the `calevent:` alias update-path.

### 4b — "remember this" in a target/track Discuss chat (`memory.sources.chats`)

The opt-in owner-rank pin. Pick a **track** with a clear channel/member subject entity (`./watchtower memory recall …`).

1. `./watchtower config set memory.sources.chats true`. Open the Desktop app, open that track's **Discuss** chat, and type an ordinary drafting turn (e.g. *"reword my last reply to be firmer"*), then `./watchtower memory consolidate`. Expect: the drafting turn is **consumed by the chat-turn floor but NOT staged** — no owner evidence, no belief change (an ordinary target/track turn is a drafting instruction, not a world statement).
2. In the same track Discuss chat, type `remember this: <a real fact about the track>` (e.g. *"remember this: this track is blocked on legal until Q4"*), then `./watchtower memory consolidate` (with `memory.semantic.enabled true`). Expect: the turn stages (run-done log `surfaces: N chat-turns`); the belief pass mints a canonical `- owner <for|against> chat:<conversation_id> <ts>` line (weight owner) on a belief about the track's subject entity — the prefix stripped for the statement. Verify the elevation is **authored, not claimed** (the model op carried no rank; only the `chat:` ref resolving to a `role='user'` turn in an **allowed context type** made it owner rank).
3. **Situation chats unchanged.** In a **situation** Discuss chat, type an ordinary owner turn (no command) and `consolidate`: it still stages every owner turn (Phase-4 behavior, unchanged) — the command is only required for target/track chats.
4. **Gate-off invariant.** `./watchtower config set memory.sources.chats false`, re-open the same track chat, type another `remember this: …`, and `consolidate`: the track turn is **never scanned** (the context-type set is `{"situation"}` exactly), no owner evidence is minted, the chat-turn floor for that turn is unmoved. Confirm the Discuss prompt and every `TestMemory09_*` situation guard remain byte-identical to Phase-4.

### 4c — Substrate invariants (MEM-05 + MEM-09 + MEM-12)

- **MEM-05:** with both sources on, the calendar builder and the generalized-chat ingest wrote **no** `inbox_items`/`situations`/`situation_signals`/`tracks`/`targets` row and never moved `inbox_last_processed_ts` (`grep -rn "inbox_\|situations\|tracks\|targets" internal/memory/` shows reads only; dump the tables before/after a `consolidate` and diff).
- **MEM-09:** owner rank is minted **only** from a `role='user'` turn resolved through the flag-derived context-type set — an assistant target/track turn, or any target/track turn with `memory.sources.chats` off, mints nothing.
- **MEM-12:** a provenance ref of a bogus scheme is **rejected at write, counted, never written**; the calendar episode carries only its single `cal:` ref (validated through the cal-only scoped registry); a `cal:` id swept from the DB drops-and-counts, the episode discarded ref-less.

Abort criteria (in addition to Sections 0–3): **any** inbox write from the calendar or chat step; **any** owner-rank line minted from a non-`role='user'` source; **any** target/track drafting turn staged without the "remember this" command; a calendar episode written with an unresolved or non-`cal:` provenance ref; or either source doing work while its gate is off — stop and report (these break MEM-05/09/12).

## Section 5 — Phase 5 slice 3: digest render-inversion (dark compare-mode)

`memory.renders.digest_compare` defaults false. First confirm the **dark-default invariant**: with it false, one `consolidate` is byte-identical to post-Slice-2 behavior — no render call, no `memory_digest_shadow` row written, no report, the run-done log's `compare: 0 shadowed`. This is a **diagnostic-only** slice: nothing user-visible changes, the legacy digest pipeline stays authoritative, and the compare only reads `digests`/`digest_topics`/`messages` and writes the memory-owned `memory_digest_shadow` side table + a branch report. The gate is the go/no-go for the future switch off legacy (a later slice).

Prereq: the legacy channel-digest pipeline must have written recent `channel` digests (`./watchtower sync` on a Slack workspace with traffic, or wait for a daemon cycle), and the memory extractor must have built episodes over roughly the same windows (`memory.enabled` on, one or more `consolidate` passes) — otherwise the compare has no episodes to render from and every window reads coverage 0.

### 5a — Run the compare + read the report

1. `./watchtower config set memory.renders.digest_compare true`, then either let a daemon cycle run or invoke the diagnostic directly: `./watchtower memory digest-compare --since 168h --out docs/specs/memory-digest-compare-report.md`. Expect the CLI to print `N channel(s) shadowed` and write the markdown report. (In the daemon, the compare runs as a tail sub-step of `phaseMemory` after extraction — the run-done log shows `compare: N shadowed (M failed, K refs rejected)`.)
2. Open the branch report. Confirm the **aggregate ref-validity** table shows the legacy `key_messages` ref-validity around the audit's **~0.6% valid** (the vast majority of legacy `key_messages` ts do NOT resolve against `messages` — the hallucination the render-inversion exists to kill) versus the **memory render at 100%** (valid by construction, MEM-13). Confirm per-channel coverage is plausible (a channel whose window the extractor fully processed should read high; a channel with extraction lag reads lower — a coverage gap, not a fabricated miss), topic counts are comparable, and the length ratio shows the memory render is not wildly longer than legacy.

### 5b — Hand-review protocol (the switch gate)

For **N random channels** in the report (N ≥ 5, or every channel if fewer), read the legacy digest and the memory render **side by side**:

1. Pull the legacy digest: `./watchtower digest show <channel>` (or query `digests`/`digest_topics` for the `legacy_digest_id` in the shadow row). Pull the memory render from the shadow row (`SELECT rendered_json FROM memory_digest_shadow WHERE channel_id=? ORDER BY period_to DESC LIMIT 1`).
2. **Grade the render's quality ≥ legacy:** does the memory render capture the same stories, decisions, and action items the legacy digest did, without inventing content the episodes don't support? A render that drops a real topic the legacy digest caught (because the extractor never built an episode for it) is an **extraction-coverage** finding, recorded against the `coverage` metric — not a render-quality failure.
3. **Verify every memory `key_messages` ts resolves:** spot-check that each ts in the render opens a real message in Slack (or resolves via `MessageExists`). By MEM-13 this must be 100% — a single unresolvable render ts is an abort-level finding (the write-time validation leaked).

### 5c — Slice invariants (MEM-13 + legacy-untouched)

- **Legacy-untouched:** dump `digests` + `digest_topics` before and after a compare run and confirm they are **byte-identical**; confirm no digest bound/watermark moved and no `digests`/`digest_topics` row was written (`grep -rn "digests\|digest_topics" internal/memory/digest_compare.go` shows reads only). The compare writes **only** `memory_digest_shadow`.
- **MEM-13 (inject a bogus render ref):** temporarily point the render prompt at a fixture (or hand-craft a shadow input) whose model reply cites a `key_messages` ts absent from every input episode and not a resolving gap message; confirm it is **dropped and counted** in `render_refs_rejected`, never written to the shadow row. `TestMemory13_RenderCitesOnlyEpisodeProvenance` guards this mechanically; the drill confirms it end-to-end on live data.

**Go/no-go for the switch (a later slice):** the compare is a GO for planning the switch off legacy only when, across the hand-reviewed channels, the memory render's quality grades **≥ legacy** on stories/decisions/actions, ref-validity is 100% (MEM-13 holds on live data), and coverage is high enough that the render is not systematically missing real topics (extraction lag understood and acceptable). Any of: a render-quality regression the coverage metric does not explain, a leaked unresolvable render ref, or a legacy-table mutation — is a **no-go**, stop and report.

Abort criteria (in addition to Sections 0–4): **any** `digests`/`digest_topics` mutation or digest-bound move from the compare; **any** memory render `key_messages` ts that does not resolve (MEM-13 leak); or the compare doing work with `memory.renders.digest_compare` off — stop and report.

## Section 6 — Phase 5 slice 4: entity mirrors, read surfaces, preference beliefs

All four gates default false (`memory.sources.operational`, `memory.surfaces.day_plan`, `memory.surfaces.meeting_prep`, `memory.semantic.preferences`). First confirm the **dark-default invariant**: with all four off, one `consolidate` + one day-plan generation + one `meeting-prep` are byte-identical to post-slice-3 behavior apart from the prompt-version labels (`day_plan.generate` v3, `meeting.prep` v4, rendered with sentinels); the run-done log shows `mirrors: 0 mirrored`, no `target:`/`track:` entity is created, and the belief-pass user message is byte-identical to slice 3's for identical inputs. Then run the drills.

1. **Mirrors (`memory.sources.operational`).** `./watchtower config set memory.sources.operational true`; on the dashboard create/convert a situation into a **Target**; run `./watchtower memory consolidate`. Confirm a `target:<id>` entity exists (`./watchtower memory recall …` / `memory open` via the alias) with `## What` = the target text/intent/level, `## Current` matching the target's status/priority/ball-on/due, `## Open loops` populated with the open sub-items, and a `## Links` line to the originating `situation:<id>` episode. Change the target's status and re-run — `## Current` refreshed, **one** commit. Re-run unchanged — **NO** new commit (content-equality no-op, `git -C …/memory log --oneline` count steady). Mark it done — `## Open loops` **cleared** (heading kept, empty). Repeat for a **Track** (`track:<id>`, sub-items in open loops, `Sub-items: N/M done` in Current). **MEM-14 spot check:** dump `targets`/`tracks`/`day_plans` before and after — byte-identical; the mirror step wrote only the vault + memory index (`grep -rn "UPDATE targets\|INSERT INTO targets\|UPDATE tracks\|INSERT INTO tracks\|UPDATE day_plans\|INSERT INTO day_plans" internal/memory/` shows no memory-side operational write).
2. **Day plan (`memory.surfaces.day_plan`).** `./watchtower config set memory.surfaces.day_plan true`; regenerate the plan (`./watchtower day-plan --force` or wait for the daemon window). Confirm the prompt's `MEMORY OPEN LOOPS` block lists a loop the TARGETS section alone did not carry (e.g. a track's stalled sub-item, or a converted-story loop), framed model-mediated, and that **no plan item duplicates a target already scheduled** (the dedupe instruction held). Gate off → the block is the sentinel `(no memory open loops)` and the plan is unaffected; the gather never created a vault and left the vault git log unchanged.
3. **Meeting prep (`memory.surfaces.meeting_prep`).** `./watchtower config set memory.surfaces.meeting_prep true`; `./watchtower meeting-prep next` for a meeting with a **known** attendee (a person entity from Slack/mail/calendar). Confirm the brief carries that attendee's memory-page excerpt (`## What`/`## Current` first lines + a few `## Facts` bullets) and up to ~3 beliefs (with confidence/status, a `shaken` belief shown as shaken), framed model-mediated ("notes and beliefs the secretary derived … not the attendee's own words"). An attendee with **no** entity degrades to a clean per-attendee absence line, never an error; vault absent → the sentinel `(no memory context)`. No vault write across a prep run.
4. **Preference beliefs (`memory.semantic.preferences`).** With `memory.sources.actions`, `memory.semantic.enabled`, and `memory.semantic.preferences` all on: over a few cycles, **dismiss** several situations sharing a subject (e.g. one noisy channel). Confirm the belief pass eventually proposes a **preference belief** on that entity (`memory recall`/`open`) — confidence ≤ 0.6, `owner-action` evidence lines citing **real** `act:` refs, statement subject a Known-subject id copied verbatim — and that it appears in the briefing revision journal. **Contest it** in a situation Discuss chat ("that channel matters to me") and confirm the owner statement **outweighs** it (shake/weaken — owner rank beats owner-action, and `owner-action` never confers MEM-06 protection). Confirm a **single** dismissal never births a belief on its own (the pattern instruction holds on live data); confirm the model op carried no rank field (MEM-08/MEM-15). Gate off → the belief-pass user message is byte-identical to slice 3's.
5. **Abort criteria** (in addition to Sections 0–5): any memory-side write to `targets`/`tracks`/`day_plans` (MEM-14 leak); any `owner-action` evidence line citing a non-existent interaction row (MEM-15 leak); a preference belief auto-retiring an owner-rank belief (MEM-06 leak); or any gated path doing work with its flag off — stop and report.

## Deliverable

`docs/specs/memory-final-validation-report.md` on this branch: per-section results, hand-review grades with anonymized examples (never raw message text), cost table, and the go/no-go verdict for merging PR #36 to main. Abort criteria from the E2E task still apply (watermark regressions, >20% ref rejection, machine content in owner-edit commits — stop and report).
