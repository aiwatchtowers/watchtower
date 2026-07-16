# Behavior Inventory — Secretary Memory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/memory/`, `internal/db/memory.go`,
> the daemon's `phaseMemory`, `internal/mcp/memory.go`, or `cmd/memory.go`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/memory/` (vault, index, resolver, seed, ingest, extract, pipeline; Phase 3: `belief_math.go`, `beliefs.go`, `rewrite.go`, `dedupe.go`, `concepts.go`, `evict.go`, `worldmap.go`; Phase 4: `chat_ingest.go`, `reflect.go`) + `internal/db/memory.go` (incl. `memory_entity_hints`, ingest floor, `memory_dispute_flags`, chat-turn floor) + `internal/briefing/memory_revisions.go` (revision journal) + `internal/inbox/watchtower_detector.go` (dispute detector) + `internal/daemon/daemon.go` (`phaseMemory`) + `internal/mcp/memory.go` (`memory_map`/`memory_open`/`memory_recall`) + `WatchtowerDesktop/.../SituationChatViewModel.swift` (Discuss MEMORY block) + `cmd/memory.go`
**Last full audit:** 2026-07-16 (Phase 4 surfaces)

## MEM-01 — Validated provenance: no hallucinated message refs

**Status:** Enforced

**Observable:** No message reference is ever written to the vault unless it resolves against the local `messages` table at write time (`SELECT 1 FROM messages WHERE channel_id=? AND ts=? AND is_deleted=0` — a tombstoned message would 404 for the owner just like a hallucinated one). A ref the extractor invented — a year-shifted ts, a wrong channel — is dropped and counted (`refs_rejected`), never "fixed up" to a nearby real message. An episode whose refs *all* fail validation is discarded entirely, not written ref-less. The same re-validation applies to situation ingest: signal message refs are checked again before being copied into an episode's `## Provenance` section, even though detector-written refs resolve 100% in practice; the rejected count is logged there too, never discarded silently.

A lookup **error** is not an invalid ref: when the existence check itself fails (DB error), `validateRefs` propagates the error instead of counting the ref as dropped — the extraction window FAILS (watermark frozen, nothing written, re-extracted next run) and the affected situation is skipped for that ingest run (logged, ingest continues with the next situation). Only a positive not-found drops and counts.

**Why locked:** Provenance is the memory's trust anchor — every fact in the vault is supposed to link back to a real message the owner can open. One hallucinated link that 404s in Slack poisons trust in every other link; silently repairing refs would be worse, attributing a claim to a message that never said it. Drop-and-count keeps the vault verifiable and makes extractor hallucination measurable instead of invisible. Conflating a failed check with a failed ref would silently discard verifiable provenance (or entire episodes) whenever the DB hiccups — the error path must freeze, not drop.

**Test guards:**
- `internal/memory/extract_test.go::TestMemory01_HallucinatedRefsDropped`
- `internal/memory/extract_test.go::TestMemory01_LookupErrorIsNotAnInvalidRef`
- `internal/memory/pipeline_test.go::TestMemory01_LookupErrorFreezesWatermark`

**Locked since:** 2026-07-15

## MEM-02 — Rebuildable index: files are the source of truth

**Status:** Enforced

**Observable:** The SQLite index (`memory_nodes`, `memory_aliases`, `memory_fts`) is purely derived state. Dropping all memory index tables and running `watchtower memory reindex` (`memory.Rebuild`) reproduces an index equivalent to the one maintained incrementally across many `Reconcile` passes with edits, alias changes, and file deletions in between — the guard test compares full table dumps (ignoring `indexed_at`). `memory_node_stats` is deliberately excluded: access counts are runtime telemetry, not derivable from files, and their reset on rebuild is accepted v1 behavior.

**Why locked:** "Markdown + git is the memory, SQLite is a cache" is the architecture's core promise — it is what makes owner edits in any editor safe and the vault portable. If the index ever accumulated state not reproducible from the files, reindex would silently lose data and the files would stop being trustworthy as the canonical copy.

**Test guards:**
- `internal/memory/index_test.go::TestMemory02_ReindexEquivalence`

**Locked since:** 2026-07-15

## MEM-03 — Owner edits are sacred: separate commit, never mixed

**Status:** Enforced

**Observable:** At the start of every consolidation run, if the vault working tree differs from HEAD (the owner hand-edited files in Obsidian or any editor), the diff is committed *first* as its own `memory(owner-edit): manual changes` commit before any machine write of that run. A subsequent machine commit's tree diff contains only machine-written paths — owner changes never ride along inside a machine commit, and machine writes never land in the owner-edit commit. A clean tree produces no owner-edit commit.

**Why locked:** The vault is advertised as owner-editable ("open it in Obsidian, fix what the secretary got wrong"). If a machine commit could swallow the owner's uncommitted edits, `git log` could no longer distinguish what the owner asserted from what the AI wrote — which destroys both auditability and the future Phase 3/4 features (reflection, belief revision) that read the commit history to know whose statement a line is.

**Test guards:**
- `internal/memory/vault_test.go::TestMemory03_OwnerEditsSeparateCommit`

**Locked since:** 2026-07-15

## MEM-04 — Chunk atomicity: watermark freezes on AI failure

**Status:** Enforced

**Observable:** The extraction watermark (`workspace.memory_last_extracted_ts`) advances only after the corresponding channel window's vault commit succeeded, and never past a message that belongs to a failed or still-pending window (`safeWatermark` in `pipeline.go`). When the AI call fails for one window, that window's messages stay above the watermark and are re-extracted next run, while earlier windows' episodes stay committed and the run still completes with status `done` — the failure is isolated to its `pipeline_steps` row (`status='error'`), catchup-style. A crash between a vault commit and the watermark write re-processes the chunk rather than skipping it.

**Batch-level isolation granularity (2026-07-15, owner-approved):** windows for quiet channels are grouped into one AI call before extraction (`groupWindowsIntoBatches`, capped by `memory.batch_max_channels`/`memory.batch_max_messages`, default 20/1500 — same digest-pipeline precedent as `digest.channel_batch`'s `groupIntoBatches`), so "the corresponding window" above can mean several channels sharing one call. Isolation is per-*batch*, not per-channel, when a batch holds more than one window: one bad reply freezes every channel in that batch together (all re-extracted next run), not just the one that would have failed alone. A window whose own message count already meets or exceeds the batch message cap still gets a solo batch — busy channels keep the original per-channel granularity; only channels too quiet to fill a batch alone trade isolation precision for fewer AI calls. Both the single-channel prompt (`memory.extract_episodes`) and the batched one (`memory.extract_episodes_batch`) share the same JSON schema — `refs[].channel_id` already disambiguated provenance per message before batching existed, so MEM-01 needed no change.

"Failure" includes shape-degenerate extractor replies: JSON that parses but whose episodes ALL carry zero refs (a misnamed `refs` key, wrong nesting) fails the window and freezes the watermark exactly like an AI error — it is never read as routine chatter. A genuinely empty `[]` remains a clean no-episode window and advances. Shape-degenerate episodes are counted (`RunStats.Malformed`).

Whole-second safety: `messages.ts_unix` is truncated to whole seconds, so the message loader (`ListMemoryExtractMessages`) drains the chunk boundary — when the chunk cap cuts inside a second, ALL rows sharing that second are loaded (slightly exceeding the cap) so the watermark second is always fully processed and the strict `ts_unix > watermark` reload can never permanently skip same-second rows.

Window bounding: one window holds at most `memory.max_window_messages` messages (default 200); a busier channel forms multiple sequential windows in the same run, so a single poison window cannot blow the model context or stall the whole channel at full cost. A later window of a channel never advances the watermark past an earlier failed window of the same channel.

Per-batch durable advance (2026-07-16, E2E watermark-loss root cause): `buildWindows` orders windows by their FIRST message ts, and the watermark is written (autocommit `UPDATE`, WAL-durable) after EVERY committed batch, not just at run end. `safeWatermark`'s bound is the earliest first-ts among still-pending windows, so first-ts ordering lifts that bound as early batches complete; the previous last-ts ordering parked any long-spanning window (early first message, late last message) in the final batch, whose early first-ts clamped the bound at the run's start — the per-batch `SetMemoryWatermark` call existed but never fired, so an interrupted run silently lost EVERY committed batch's advance together and re-extracted the whole run as duplicates (docs/specs/memory-e2e-report.md, "Second issue found"). An interrupted run now loses at most the tail at/above the last safe advance: the in-flight batch plus the not-yet-covered tail messages of windows that overlap it.

**Why locked:** The watermark only ever moves forward, so any window it skips is lost to memory forever. Advancing on failure would mean a transient model error silently drops a day of history from the vault with no way to notice; freezing trades a cheap re-extraction for zero lost windows — the same freeze discipline INBOX-09 established for the inbox watermark. The same reasoning covers degenerate-shape replies (a schema drift would otherwise silently discard every episode while looking like healthy chatter) and same-second truncation (a chunk cut inside one busy second would silently drop the rest of that second forever).

**Test guards:**
- `internal/memory/pipeline_test.go::TestMemory04_WatermarkFreezeOnAIFailure`
- `internal/memory/pipeline_test.go::TestMemory04_ShapeDegenerateJSONFreezesWatermark`
- `internal/memory/pipeline_test.go::TestMemory04_SameSecondChunkCapNeverSkips`
- `internal/memory/pipeline_test.go::TestMemory04_InterleavedWindowFreeze`
- `internal/memory/pipeline_test.go::TestMemory04_LaterWindowNeverPassesEarlierFailedWindow`
- `internal/memory/pipeline_test.go::TestGroupWindowsIntoBatches` (grouping function: message/channel caps, oversized-window solo batch)
- `internal/memory/pipeline_test.go::TestBatchGroupsQuietChannelsIntoOneCall` (one call, correct per-channel provenance)
- `internal/memory/pipeline_test.go::TestBatchFailureFreezesAllChannelsInBatch` (batch-level freeze)
- `internal/memory/pipeline_test.go::TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark` (per-batch durable advance: an interrupted run keeps committed batches behind a watermark visible from a second connection; only the frozen batch and uncovered tails re-extract)
- `internal/memory/pipeline_test.go::TestBuildWindowsOrdersByFirstTS` (first-ts window ordering that makes per-batch advance possible)

**Locked since:** 2026-07-15

## MEM-05 — Inbox isolation: consolidation is a pure reader

**Status:** Enforced

**Observable:** Memory consolidation reads situations, inbox items, and messages but writes nothing to any inbox table (`inbox_items`, `situations`, `situation_signals` stay byte-identical across a run — the guard test compares full dumps) and never moves `inbox_last_processed_ts`. Even ingest bookkeeping stays out of the main DB: "already ingested" is tracked via the `situation:<id>` alias on the episode node, not a column on `situations`. All INBOX-01..09 and DASH-01..07 contracts are untouched by the memory phase.

**Why locked:** Memory v1 is a consumer bolted on after the inbox pipeline; its whole safety argument is "it cannot break what exists." A single write into inbox tables — or a watermark nudge — would entangle two pipelines' failure modes and silently violate the inbox module's own contracts from outside that module's guard tests.

**Test guards:**
- `internal/memory/ingest_test.go::TestMemory05_InboxUntouched`

**Locked since:** 2026-07-15

## MEM-06 — Owner-rank belief protection: observation never auto-flips an owner belief

**Status:** Enforced (Phase 3, `memory.semantic.enabled`)

**Observable:** A belief node carrying non-decayed owner-rank evidence (owner-authored support younger than the 180-day decay horizon) is never automatically retired or flipped by observed/inferred contradiction. In the belief pass (`ReviseBeliefs` → `applyOp`), a model `retire`/flip op against such protected owner support is downgraded — the belief lands `shaken` at most, never `retired`, regardless of how much observed contradiction accumulates. Owner weight decays linearly `1.0 → 0.4` over 180 days; only once it drops below the threshold does a retire apply. A `shake` is always allowed (active → shaken) — protection blocks retirement/flip, not the softer "buffer" transition. Owner-rank protection requires the owner support to be written as a **canonical evidence line** (`- owner for <channel_id> <ts>`); a prose evidence bullet does not parse (it is logged and ignored by `parseBeliefEvidence`), so it carries no rank weight and cannot protect a belief.

**Why locked:** The owner is the authority on their own world. If a run of AI-observed contradictions could silently retire a fact the owner asserted, the memory would quietly overwrite the owner's own statements with model inference — the exact inversion of MEM-03's "owner edits are sacred." Asymmetric hysteresis (cheap to shake, expensive to flip, impossible to auto-flip over fresh owner support) keeps the belief graph anchored to what the owner actually said.

**Test guards:**
- `internal/memory/beliefs_test.go::TestMemory06_OwnerRankBeliefNeverAutoFlipped` (full `ReviseBeliefs` seam)
- `internal/memory/belief_math_test.go::TestApplyOp*` / `TestOwnerRankWeight` (exhaustive pure-math coverage of the rank/decay/downgrade rules)

**Locked since:** 2026-07-16

## MEM-07 — Provenance never thins: eviction and merge preserve every ref

**Status:** Enforced (Phase 3, `memory.semantic.enabled`)

**Observable:** No consolidation step ever drops a provenance ref. Eviction (`EvictEpisodes`) collapses a cold closed long-tier episode into a per-channel-per-month rollup (`sum_*`) whose gist line carries **every** provenance ref of the evicted episode verbatim; the episode file becomes a tombstone redirecting to the rollup (the resolver chases old `[[ep_*]]` links, the rollup line stays FTS-searchable), and its aliases move to the rollup. Nothing is deleted. Dedupe (`DedupeEpisodes` → `Merge`) is the same discipline for merges: a partial-overlap merge unions the loser-only refs into the winner's `## Provenance` before the merge, so a merge never thins provenance either. A second eviction into the same channel-month appends to the existing rollup rather than duplicating it.

**Why locked:** Provenance is the memory's trust anchor (MEM-01). Compression that silently loses even one ref would break the promise that every retained fact links back to a real message — and eviction/merge, which touch the OLDEST records (least likely to be re-derived), are exactly where a dropped ref would be unrecoverable. Rollups trade episode-level narrative for space while keeping the audit trail intact.

**Test guards:**
- `internal/memory/evict_test.go::TestMemory07_EvictionKeepsProvenance` (verbatim rollup refs + tombstone chase + FTS + the dedupe-union case)
- `internal/memory/dedupe_test.go::TestDedupeUnionsPartialOverlapProvenance`

**Locked since:** 2026-07-16

## MEM-08 — Model proposes, code disposes: AI output reaches the vault only through validation

**Status:** Enforced (Phase 3, `memory.semantic.enabled`)

**Observable:** No strong-tier AI output ever mutates the vault directly. Belief ops from `memory.revise_beliefs` are applied only when the Go rank/threshold math (`applyOp`) permits the transition — the model proposes an op (`confirm`/`weaken`/`shake`/`retire`/`propose-new`) but never sets confidence/status/stability (extra JSON keys the op schema does not carry are ignored; birth confidence is computed and capped at 0.6). An op whose cited evidence refs are all invented (absent from the run's supplied episodes) is dropped and never reaches `applyOp`. Provenance markers from `memory.entity_rewrite` are validated the MEM-01 way — a marker not present in the input episode set is dropped and counted, never written. A `propose-new` whose subject does not resolve to an existing entity is rejected.

**Why locked:** The semantic tier lets a strong model rewrite pages and revise beliefs — far more consequential than the light-tier extractor. If the model's self-reported confidence or an invented citation could land in the vault unchecked, a single confident hallucination would corrupt the belief graph with fabricated certainty and unverifiable provenance. Keeping every AI output behind a code-side gate makes model influence auditable and bounded by the same provenance discipline as everything else.

**Test guards:**
- `internal/memory/beliefs_test.go::TestMemory08_BeliefOpsGatedByRankMath` (self-declared confidence ignored, invented evidence rejected, rewrite marker validated)
- `internal/memory/rewrite_test.go::TestRewriteEntityPagesDropsInventedMarker`
- `internal/memory/belief_math_test.go` (the disposing math)

**Locked since:** 2026-07-16

## MEM-09 — Owner rank is authored, never inferred

**Status:** Enforced (Phase 4, `memory.surfaces.chat`)

**Observable:** Owner-rank belief evidence (`- owner <for|against> chat:<conversation_id> <ts>`) is minted **exclusively by code**, only for a `chat:` evidence ref that resolves to a `role='user'` turn in a `context_type='situation'` Discuss conversation (`OwnerChatTurnExists`), or from a `memory(owner-edit)` vault commit. The belief-op JSON schema (`beliefOpJSON`) carries **no rank field**, so no model output can name, introduce, or upgrade evidence to owner rank — the model only cites a ref and chooses a direction; `newEvidenceLines` elevates a validated `chat:` ref to `rankOwner`, every other ref stays `rankObserved`. A `chat:` ref the model cited but that was never staged this run, resolves to a `role='assistant'` turn, points at a non-situation conversation, or hits absent chat tables (headless daemon) is dropped and counted like an invented episode ref (`validateChatRefs`, MEM-01 discipline) — never minted at owner rank.

**Why locked:** Owner rank is the highest-trust input in the belief math (MEM-06 protection hangs on it): non-decayed owner support blocks auto-retirement. If a model could mint or claim owner rank, a confident hallucination would forge the owner's own voice and permanently protect a fabricated belief — the exact inversion of MEM-03/MEM-06. Keeping the elevation a pure code path keyed on `role='user'` provenance makes "the owner said this" verifiable, never inferred.

**Test guards:**
- `internal/memory/chat_evidence_test.go::TestMemory09_OwnerRankOnlyFromAuthoredTurns`
- `internal/memory/chat_evidence_test.go` (chat-ref grammar, staged-ref minting, assistant/non-situation/absent-table drops)

**Locked since:** 2026-07-16

## MEM-10 — Disputes ride the standard inbox: memory never writes an inbox table

**Status:** Enforced (Phase 4, `memory.surfaces.disputes`)

**Observable:** MEM-05 restated for the Phase-4 dispute surface. The memory pipeline marks a dispute-worthy belief by inserting into the `memory_dispute_flags` side table (a memory-owned runtime table, `memory_node_stats` precedent) — it never writes `inbox_items` / `situations` / `situation_signals` and never moves `inbox_last_processed_ts`, even with a dispute flag set and every surface gate on (the guard compares full table dumps across a run). Dispute trigger items are created **only** by the inbox pipeline's watchtower detector (`internal/inbox`, `detectMemoryDisputes`), which reads a flagged belief, mints one `decision_made` item (`channel_id="memory"`, `message_ts="dispute:<belief_id>"`), and clears the flag in the **same** DB transaction so a dispute surfaces exactly once (cap ≤2 per cycle, `memoryDisputeCap`). From there the standard pipeline owns it — INBOX-01 (never dropped/upgraded), INBOX-09 (watermark), and DASH-01/02 are structurally untouched because it is an ordinary detector item created before triage.

**Why locked:** Memory is a consumer bolted onto the inbox pipeline; its whole safety argument is "it cannot break what exists" (MEM-05). Splitting the dispute flow — memory flags, the inbox package that legitimately owns `inbox_items` mints and consumes — keeps that boundary intact: a dispute is subject to every INBOX/DASH contract without the memory package ever reaching across into inbox tables. A single memory-side inbox write would entangle two pipelines' failure modes and violate the inbox module's contracts from outside its own guard tests.

**Test guards:**
- `internal/memory/reflect_test.go::TestMemory10_DisputeFlagsNeverTouchInboxFromMemory` (memory side: inbox tables byte-identical, watermark untouched, flag unconsumed)
- `internal/inbox/watchtower_detector_test.go::TestWatchtowerDetector_DisputeMinted` / `DisputeSecondRunNoDuplicate` / `DisputeCapPerCycle` / `DisputeGateOff` / `DisputeMintErrorLeavesFlag` (inbox side: mint + same-tx clear + cap + gate + rollback)

**Locked since:** 2026-07-16

## MEM-11 — Surfaces are read-only over belief history

**Status:** Enforced (Phase 4, `memory.surfaces.briefing`/`memory.surfaces.reflection`)

**Observable:** The Phase-4 read surfaces never mutate a belief. The briefing revision journal (`internal/briefing`, `gatherMemoryRevisions`) only reads the index + vault (`ListMemoryNodes` + `ReadNode`) to render notable belief transitions. The weekly reflection pass (`Reflect`) reads the vault git log + `## History` churn and applies its observations by code as ONLY (a) a `dispute_pending` side-table flag on a flapping belief and (b) a dated bullet appended to a flapping entity page's `## Current` section (an ordinary `memory(reflect)` commit) — every belief's `confidence`/`status`/`stability` and body stay byte-unchanged across a reflection run. All belief-math mutations still flow solely through `applyBeliefOp`/`applyOp` (the Phase-3 rank math); no surface writes a belief's confidence or status directly.

**Why locked:** The one-line rule of the whole memory design is "never ask before a revision; always show after." The surfaces exist to *show* history, not rewrite it. If a briefing render or a reflection pass could nudge a belief's confidence or status, belief evolution would have two uncoordinated authors — the rank math and the surfaces — and the confidence numbers the owner reads in the journal would no longer be the ones the math produced. Confining reflection to dispute flags + entity notes keeps belief state single-sourced and the surfaces auditable as pure readers.

**Test guards:**
- `internal/memory/reflect_test.go::TestMemory11_SurfacesDontMutateBeliefs` (reflection flags a dispute + appends an entity note; every belief's confidence/status/stability/body byte-unchanged)
- `internal/memory/reflect_test.go::TestReflectFlapsBeliefToDispute` / `TestReflectEntityNoteAppendsCurrent` (each disposition applied by code alone)

**Locked since:** 2026-07-16

## Known v1 limitations (not contracts, but do not "fix" silently)

- **Cache-token split is approximated.** `pipeline_runs` records cache reads and cache creation in separate columns (migration adding `cache_read_tokens`/`cache_creation_tokens`), but `digest.Usage` only exposes a combined API total — so the pipeline records the residual (total API tokens minus prompt tokens) under `cache_read_tokens` and leaves `cache_creation_tokens` at 0 until `Usage` grows the real split (`completeRun` in `pipeline.go`). Numbers in the two columns are an estimate, not provider truth.
- **Access stats never count today.** `memory_open` bumps `memory_node_stats` with an ignored error — but every production MCP surface runs the database in read-only (query_only) mode, so the write always fails there and the counters simply never increment. The columns are dead telemetry in v1, not an under-count: Phase 3 (retention scoring, eviction) must NOT build on them until a writable stats path exists.
- **MEM-02 diverges on quarantined files.** Incremental `Reconcile` preserves the last-good index row of a file it quarantines (parse failure after an owner edit), but a full `Rebuild` drops the index first — the quarantined node then has no row at all until the file is repaired. The reindex-equivalence contract is stated for healthy vaults; with quarantined files present the two paths intentionally differ (stale-but-searchable vs absent).
- **MEM-03 has a crash window.** The owner-edit commit is not atomic with the machine writes that follow: if the process is killed between a machine file write and its commit, those machine-written files sit uncommitted in the worktree and the NEXT run's `CommitOwnerEdits` sweeps them into a `memory(owner-edit)` commit — machine text mislabeled as the owner's. Rare (requires a kill inside a narrow window) and self-limiting, but `git log` attribution is not crash-proof; do not present it as such, and do not "fix" it casually — a proper fix needs a staging/journal step.
- **Vault text is framed as model-mediated (shipped in Phase 4).** Episode bodies and entity rewrites are AI summaries of third-party messages — model-mediated hearsay with provenance links, not the owner's own notes. The Phase-4 surfaces present vault content as such: the Swift Discuss MEMORY block is labeled "notes the secretary has built from Slack/Jira — model-mediated, not the owner's own words," and the briefing revision journal frames each line as "notes derived from Slack/Jira, model-mediated." Only `chat:` owner evidence (MEM-09) and `memory(owner-edit)` commits carry owner-asserted text. Do not reword these surfaces to imply the owner authored vault prose.
- **`memory_dispute_flags` is runtime side-table state, excluded from MEM-02, self-healing on reindex.** A belief flagged dispute-worthy (by reflection; the belief pass may flag in a later phase) is recorded in `memory_dispute_flags(node_id, flagged_at, reason)`, not on the `memory_nodes` row — the same runtime-state precedent as `memory_node_stats`, so it is outside MEM-02's dump comparison and `DropMemoryIndex`/`Rebuild` clears it. Resetting the flag on reindex is safe: a still-conflicting belief is re-flagged by the next reflection/belief pass (self-healing). The inbox watchtower detector reads and clears the flag (MEM-10); the flag is consumed exactly once per surfaced dispute.
- **`chat:` evidence grammar depends on Swift-owned tables.** Owner Discuss turns become belief evidence via a `chat:<conversation_id>` channel-id in the canonical evidence line, resolved against `chat_conversations`/`chat_messages` — tables the Desktop app creates lazily (GRDB) the first time the owner opens a Discuss chat. On a headless daemon they are absent; both `ingestChatStatements` and the belief pass's `validateChatRefs` treat their absence as an empty read (never an error), so the chat surface is a clean no-op until the app has created them. Turn identity is `chat_messages.id` (the ingest floor); turn ts is `chat_messages.created_at` truncated to whole seconds.
- **Failed-window re-extraction can duplicate episodes (now mopped up by dedupe).** Per MEM-04, a failed window is re-extracted next run — but extracted episodes get fresh ULIDs, so a window that partially succeeded before failing (or a crash between vault commit and watermark write) can produce near-duplicate episode nodes. Since the 2026-07-16 first-ts-ordering fix the exposure on an interrupted run is bounded to the in-flight batch plus the uncovered tails of windows overlapping it (previously a mid-run kill could lose the WHOLE run's advance and duplicate every committed batch — the E2E incident). A long-spanning window's tail above the last safe advance still re-extracts as a tolerated duplicate: the scalar watermark prefers duplicates over skips by design. Phase 3's `DedupeEpisodes` (behind `memory.semantic.enabled`) now mops these up mechanically — provenance-ref overlap within one channel merges the newer duplicate into the older (MEM-07 unions provenance on merge). Write-time dedupe against prior extractions/situation coverage is still deferred; duplicates remain accepted at write time, cleaned on a later semantic pass.
- **`memory_entity_hints` is runtime accumulation, excluded from MEM-02, and survives reindex.** Unresolved extractor entity hints are persisted (`hint`, `episode_id`) for concept-entity promotion once a hint recurs across enough distinct episodes. Like `memory_node_stats` it is NOT derivable from vault files, so it is excluded from the MEM-02 reindex-equivalence comparison. Unlike `memory_node_stats` it is deliberately **not** cleared by `DropMemoryIndex`/`Rebuild`, so a reindex never resets promotion progress — a design choice, not a leak.
- **Retention/eviction does not use access stats.** Phase 3 retention scoring (`RetentionScore`) intentionally excludes `memory_node_stats` access counters (write-dead in production, per the access-stats limitation above): importance is `links-in + situation-origin bonus + owner-touch bonus`, where owner-touch is computed lazily from `git log` for the bounded eviction-candidate set only. No score is stored in a file or column — it is recomputed on demand from the index, keeping MEM-02 clean.
- **Raw episodes age before they can be evicted.** Extracted episodes are minted active/short and only *situation-finalized* episodes reach closed/long through ingest — so a raw non-situation episode is never closed by extraction and would never become an eviction candidate. A mechanical aging pass (`AgeEpisodes`, runs in `runSemantic` before eviction) transitions an active short-tier non-situation episode (no `situation:*` alias — those age through ingest) whose newest provenance event is older than `memory.semantic.age_after_days` (default 14) to closed/long; the 45-day `evict_after_days` window then applies to the now-closed episode. So the two windows compose: a raw episode ages at ~14 days, then is eligible for eviction ~45 days after its last event. Situation-aliased episodes are deliberately untouched by the aging pass (their lifecycle belongs to ingest), and the pass counts into `RunStats.Aged`.
- **`map.md` is hard-capped at ~2 KB; `index.md` is the full listing.** The two-tier world map splits the old unbounded `map.md` into a mechanical `index.md` (full per-entity listing, never injected, the browsing surface behind `watchtower memory index`) and a strong-tier hot `map.md` (5–8 areas + notable beliefs, the MCP `memory_map` read target). The strong render is truncated code-side at a line boundary to ~2 KB (`capMapBytes`) — the prompt asks for brevity but cannot be trusted to obey a byte budget (the pre-split render hit 56 KB at 447 entities). With the semantic tier off, `map.md` is still produced mechanically so `memory_map` always has a target.
- **Boundary drain can exceed the chunk cap.** When `memory.max_chunk_messages` cuts inside one busy second, the loader intentionally loads the whole second (see MEM-04), so a run may consume slightly more than the cap — bounded by one second of traffic. The per-window cap (`memory.max_window_messages`) still bounds each individual prompt.
- **Malformed count is run-level only.** Shape-degenerate episode counts surface in `RunStats.Malformed` and logs; `pipeline_steps` has no dedicated column for them (the failed window's step row carries `status='error'`). Adding a column is a schema change deferred until the count proves useful.
- **Authorless messages fall back to the raw user_id.** Messages whose author has no `users` row (deleted/ex-employee, never synced) are extracted with the Slack user ID as the author label — the extractor sees `U0ABC123:` instead of a display name until the user table catches up.

## Changelog

- 2026-07-16 (Phase 4 surfaces): wired the four memory *surfaces* on top of the Phase-3 semantic tier, each dark by default behind its own gate `memory.surfaces.{chat,briefing,disputes,reflection}` (all default false, independent blast radii). (1) **Discuss chat** — the situation chat's system prompt gains a MEMORY block (hot `map.md` + index-relevant entities/beliefs + a memory-tools line, 4 KB-capped, Swift) and owner turns typed in Discuss become owner-rank belief evidence (`ingestChatStatements` stages `role='user'` situation turns; the belief pass mints `- owner …` lines from validated `chat:<id>` refs). (2) **Briefing revision journal** — `gatherMemoryRevisions` adds a *Memory revisions* block of notable belief transitions since the last briefing (`briefing.daily` bumped to v6). (3) **The arguing secretary** — the inbox watchtower detector reads `dispute_pending` beliefs and mints `decision_made` situations (memory never writes inbox tables — MEM-05/10). (4) **Reflection** — a weekly strong-tier `memory.reflect` pass over the vault git log + `## History` churn flags flapping beliefs (`dispute_pending`) and appends entity `## Current` notes (MEM-11; deterministic workspace stagger, budget-gated, tail of `runSemantic`). Three new contracts: **MEM-09** (owner rank is authored, never inferred), **MEM-10** (disputes ride the standard inbox — memory never writes an inbox table), **MEM-11** (surfaces are read-only over belief history). New migration 00019 (`memory_dispute_flags` side table, index `subject`/`confidence` belief columns, `workspace.memory_chat_turn_floor`; MEM-02 dump ignores the runtime `dispute_pending` derivation, owner-approved). New prompt `memory.reflect` (strong tier by absence from the light-tier switch).
- 2026-07-16 (Phase 3 semantic tier): added the semantic tier behind `memory.semantic.enabled` (default false) — belief nodes with rank/hysteresis math, strong-tier entity-page rewrites, provenance-keyed episode dedupe, retention scoring + eviction into per-channel-month rollups, a two-tier world map (mechanical `index.md` + strong `map.md` capped at ~2 KB), and concept-entity promotion from recurring extractor hints. Three new contracts: **MEM-06** (owner-rank belief protection — observation never auto-flips an owner belief), **MEM-07** (provenance never thins — eviction and merge preserve every ref verbatim), **MEM-08** (model proposes, code disposes — AI output reaches the vault only through the rank math + MEM-01 marker/evidence validation). Pipeline order gains, after extraction and before the renders: dedupe → concept promotion → page rewrite → belief pass → eviction, each a failure-isolated `pipeline_steps` row that never fails the run or moves a watermark; strong-tier AI steps stop launching once the run's output tokens exceed `memory.semantic.output_budget` (default 200000). New migration 00018 (belief statuses `shaken`/`retired`, `memory_entity_hints` table, `workspace.memory_last_ingested_situation_id` ingest floor). Housekeeping: `listIngestSituations` gained an ingest floor (terminal situations rescanned only above the floor; open situations always scanned — MEM-05 preserved), `watchtower memory consolidate` dropped its mandatory `--once` flag (plain invocation runs one pass), and a new `watchtower memory index` prints `index.md`.
- 2026-07-16 (E2E fix, watermark loss on killed process): root-caused the E2E report's "second issue" (all 5 committed batches' watermark advance lost together on a SIGKILL). Not a SQLite/WAL durability problem and not a missing per-batch write: `advanceWatermark` ran after every committed batch, but `buildWindows`' last-ts window ordering parked long-spanning windows (early first ts, late last ts) in the final batches, and `safeWatermark`'s pending-window bound — the earliest first-ts among unfinished windows — stayed clamped at the run's start, so every per-batch `SetMemoryWatermark` call was silently suppressed and the entire run's advance rode on the final batch. Fixed by ordering windows by FIRST message ts (stable sort, same-channel sequential windows keep chronological order), which monotonically lifts the bound as batches complete; `safeWatermark` itself is unchanged and still freezes correctly on failures. Guarded by `TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark` (file-backed DB, durability verified from a second connection, duplicate re-extraction of committed batches asserted gone) and `TestBuildWindowsOrdersByFirstTS`.
- 2026-07-16 (E2E fix): the batch prompt's user message opened with a `"--- #channel..."` delimiter — the very first bytes of the whole message, since (unlike `digest.channel_batch`'s blocks, which sit inside a larger templated prompt) this batch prompt IS the whole user message. `internal/ai/client.go` passes that message as a raw `"-p", userMessage` argv token, and the claude CLI parsed a leading `--` as an unrecognized flag rather than `-p`'s value — every batched call failed with `unknown option '--- #channel...'` on the very first live run against real data (100% of batches, 0 episodes extracted). No mocked-generator unit test could have caught it. Fixed by opening the batch prompt with a non-dash line and switching the block delimiter to `"=== #channel (id) ==="` (bumped `memory.extract_episodes_batch` to prompt v2); guarded by `TestBuildExtractPromptsNeverStartWithDash`.
- 2026-07-15 (throughput, E2E validation follow-up): quiet channels/DMs now share one extraction call instead of paying for a solo round-trip each — `groupWindowsIntoBatches` packs windows up to `memory.batch_max_channels`/`memory.batch_max_messages` (default 20/1500, digest-pipeline precedent), new prompt `memory.extract_episodes_batch` (multi-channel variant of `memory.extract_episodes`, same JSON schema — `refs[].channel_id` already disambiguated per-message provenance, so MEM-01 was untouched). MEM-04's freeze granularity is now per-*batch* when a batch groups more than one channel (owner-approved trade-off: the E2E validation run showed ~100 tiny per-channel AI calls for a single 2000-message chunk spread thin across a workspace's channels — real throughput problem, not a bug). A window whose own size already meets the batch cap still gets a solo batch, so busy channels keep v1's per-channel isolation unchanged. `pipeline_steps` gets one row per batch (channel_id populated only for a singleton batch; channel_name lists all channels otherwise) instead of one row per channel.
- 2026-07-15 (infrastructure hardening, review batch B): cross-process `memory.lock` (flock in the workspace dir, digest-pipeline precedent) taken by `Pipeline.Run` and CLI seed/reindex — contention returns "another memory run is in progress" (CLI prints, daemon logs and skips the cycle). `Reconcile` gained quarantine semantics: a per-file parse/upsert failure (Obsidian damage, unknown frontmatter key, duplicate alias) is skipped-and-counted (`Stats.Quarantined` + paths, warning logged), the file stays in the on-disk set so its existing index row is preserved; only IO/DB-wide failures error the pass. Read-only CLI subcommands (`memory open`, `memory reindex`) use `OpenExistingVault` and report "not initialized" instead of git-initing a vault as a side effect. `initVault` writes a `.gitignore` (`.obsidian/`, `.DS_Store`, `*.tmp`) so editor/OS churn never becomes an owner-edit commit. MEM-01's message-existence check now requires `is_deleted = 0`. Node IDs containing path separators or `..` are rejected before any file IO (redirect_to traversal hardening). `memory status` excludes tombstones from type/tier counts and reports them on their own line.
- 2026-07-15 (correctness hardening, same day as creation): MEM-01 extended — a provenance lookup ERROR now propagates (window fails / situation skipped-and-logged) instead of being counted as a dropped ref; ingest logs its rejected-ref count. MEM-04 extended — shape-degenerate extractor replies (parsed episodes, all zero refs) freeze the watermark instead of advancing as "no episodes"; the message loader drains same-second chunk boundaries so `ts_unix` whole-second truncation can never skip messages; new `memory.max_window_messages` (default 200) splits oversized channel batches into sequential windows; authorless messages (no `users` row) are extracted with a raw-user_id author instead of being skipped forever; a fresh workspace without its singleton row reads watermark 0 instead of failing the run. The extractor prompt moved into the standard prompt store as `memory.extract_episodes` (user-customizable, versioned) and now carries the `prompts.Directive` language instruction from `digest.language`.
- 2026-07-15: file created with 5 contracts (MEM-01..05), all Enforced. Introduced by Secretary Memory Phases 0–2 (spec `docs/superpowers/specs/2026-07-15-secretary-memory-design.md`): a markdown+go-git memory vault at `WorkspaceDir()/memory` with a rebuildable SQLite index, mechanical entity seeding, situations ingest, a light-tier raw-text episode extractor (`memory.extract_episodes`), the `phaseMemory` daemon phase (after `phaseInbox`, off by default via `memory.enabled`), MCP read tools, and the `watchtower memory` CLI. Beliefs, rollup eviction, and dedupe are Phase 3+; injecting memory into existing pipelines is Phase 4.
