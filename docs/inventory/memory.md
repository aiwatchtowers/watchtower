# Behavior Inventory — Secretary Memory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/memory/`, `internal/db/memory.go`,
> the daemon's `phaseMemory`, `internal/mcp/memory.go`, or `cmd/memory.go`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/memory/` (vault, index, resolver, seed, ingest, extract, pipeline) + `internal/db/memory.go` + `internal/daemon/daemon.go` (`phaseMemory`) + `internal/mcp/memory.go` (`memory_map`/`memory_open`/`memory_recall`) + `cmd/memory.go`
**Last full audit:** 2026-07-15

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

## Known v1 limitations (not contracts, but do not "fix" silently)

- **Cache-token split is approximated.** `pipeline_runs` records cache reads and cache creation in separate columns (migration adding `cache_read_tokens`/`cache_creation_tokens`), but `digest.Usage` only exposes a combined API total — so the pipeline records the residual (total API tokens minus prompt tokens) under `cache_read_tokens` and leaves `cache_creation_tokens` at 0 until `Usage` grows the real split (`completeRun` in `pipeline.go`). Numbers in the two columns are an estimate, not provider truth.
- **Access stats never count today.** `memory_open` bumps `memory_node_stats` with an ignored error — but every production MCP surface runs the database in read-only (query_only) mode, so the write always fails there and the counters simply never increment. The columns are dead telemetry in v1, not an under-count: Phase 3 (retention scoring, eviction) must NOT build on them until a writable stats path exists.
- **MEM-02 diverges on quarantined files.** Incremental `Reconcile` preserves the last-good index row of a file it quarantines (parse failure after an owner edit), but a full `Rebuild` drops the index first — the quarantined node then has no row at all until the file is repaired. The reindex-equivalence contract is stated for healthy vaults; with quarantined files present the two paths intentionally differ (stale-but-searchable vs absent).
- **MEM-03 has a crash window.** The owner-edit commit is not atomic with the machine writes that follow: if the process is killed between a machine file write and its commit, those machine-written files sit uncommitted in the worktree and the NEXT run's `CommitOwnerEdits` sweeps them into a `memory(owner-edit)` commit — machine text mislabeled as the owner's. Rare (requires a kill inside a narrow window) and self-limiting, but `git log` attribution is not crash-proof; do not present it as such, and do not "fix" it casually — a proper fix needs a staging/journal step.
- **Phase 4 must frame vault text as model-mediated.** Episode bodies (and future entity rewrites) are AI summaries of third-party messages — model-mediated hearsay with provenance links, not the owner's own notes. The Phase 4 injection spec (working-memory blocks, Discuss tools) must present vault content to downstream prompts as such ("memory notes derived from Slack/Jira", never "the owner wrote"); only `memory(owner-edit)` commits carry owner-asserted text.
- **Failed-window re-extraction can duplicate episodes.** Per MEM-04, a failed window is re-extracted next run — but extracted episodes get fresh ULIDs, so a window that partially succeeded before failing (or a crash between vault commit and watermark write) can produce near-duplicate episode nodes. Since the 2026-07-16 first-ts-ordering fix the exposure on an interrupted run is bounded to the in-flight batch plus the uncovered tails of windows overlapping it (previously a mid-run kill could lose the WHOLE run's advance and duplicate every committed batch — the E2E incident). A long-spanning window's tail above the last safe advance still re-extracts as a tolerated duplicate: the scalar watermark prefers duplicates over skips by design. Deduplication against prior extractions and situation coverage is deliberately deferred to Phase 3; until then duplicates are accepted, not a bug to hack around at write time.
- **Boundary drain can exceed the chunk cap.** When `memory.max_chunk_messages` cuts inside one busy second, the loader intentionally loads the whole second (see MEM-04), so a run may consume slightly more than the cap — bounded by one second of traffic. The per-window cap (`memory.max_window_messages`) still bounds each individual prompt.
- **Malformed count is run-level only.** Shape-degenerate episode counts surface in `RunStats.Malformed` and logs; `pipeline_steps` has no dedicated column for them (the failed window's step row carries `status='error'`). Adding a column is a schema change deferred until the count proves useful.
- **Authorless messages fall back to the raw user_id.** Messages whose author has no `users` row (deleted/ex-employee, never synced) are extracted with the Slack user ID as the author label — the extractor sees `U0ABC123:` instead of a display name until the user table catches up.

## Changelog

- 2026-07-16 (E2E fix, watermark loss on killed process): root-caused the E2E report's "second issue" (all 5 committed batches' watermark advance lost together on a SIGKILL). Not a SQLite/WAL durability problem and not a missing per-batch write: `advanceWatermark` ran after every committed batch, but `buildWindows`' last-ts window ordering parked long-spanning windows (early first ts, late last ts) in the final batches, and `safeWatermark`'s pending-window bound — the earliest first-ts among unfinished windows — stayed clamped at the run's start, so every per-batch `SetMemoryWatermark` call was silently suppressed and the entire run's advance rode on the final batch. Fixed by ordering windows by FIRST message ts (stable sort, same-channel sequential windows keep chronological order), which monotonically lifts the bound as batches complete; `safeWatermark` itself is unchanged and still freezes correctly on failures. Guarded by `TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark` (file-backed DB, durability verified from a second connection, duplicate re-extraction of committed batches asserted gone) and `TestBuildWindowsOrdersByFirstTS`.
- 2026-07-16 (E2E fix): the batch prompt's user message opened with a `"--- #channel..."` delimiter — the very first bytes of the whole message, since (unlike `digest.channel_batch`'s blocks, which sit inside a larger templated prompt) this batch prompt IS the whole user message. `internal/ai/client.go` passes that message as a raw `"-p", userMessage` argv token, and the claude CLI parsed a leading `--` as an unrecognized flag rather than `-p`'s value — every batched call failed with `unknown option '--- #channel...'` on the very first live run against real data (100% of batches, 0 episodes extracted). No mocked-generator unit test could have caught it. Fixed by opening the batch prompt with a non-dash line and switching the block delimiter to `"=== #channel (id) ==="` (bumped `memory.extract_episodes_batch` to prompt v2); guarded by `TestBuildExtractPromptsNeverStartWithDash`.
- 2026-07-15 (throughput, E2E validation follow-up): quiet channels/DMs now share one extraction call instead of paying for a solo round-trip each — `groupWindowsIntoBatches` packs windows up to `memory.batch_max_channels`/`memory.batch_max_messages` (default 20/1500, digest-pipeline precedent), new prompt `memory.extract_episodes_batch` (multi-channel variant of `memory.extract_episodes`, same JSON schema — `refs[].channel_id` already disambiguated per-message provenance, so MEM-01 was untouched). MEM-04's freeze granularity is now per-*batch* when a batch groups more than one channel (owner-approved trade-off: the E2E validation run showed ~100 tiny per-channel AI calls for a single 2000-message chunk spread thin across a workspace's channels — real throughput problem, not a bug). A window whose own size already meets the batch cap still gets a solo batch, so busy channels keep v1's per-channel isolation unchanged. `pipeline_steps` gets one row per batch (channel_id populated only for a singleton batch; channel_name lists all channels otherwise) instead of one row per channel.
- 2026-07-15 (infrastructure hardening, review batch B): cross-process `memory.lock` (flock in the workspace dir, digest-pipeline precedent) taken by `Pipeline.Run` and CLI seed/reindex — contention returns "another memory run is in progress" (CLI prints, daemon logs and skips the cycle). `Reconcile` gained quarantine semantics: a per-file parse/upsert failure (Obsidian damage, unknown frontmatter key, duplicate alias) is skipped-and-counted (`Stats.Quarantined` + paths, warning logged), the file stays in the on-disk set so its existing index row is preserved; only IO/DB-wide failures error the pass. Read-only CLI subcommands (`memory open`, `memory reindex`) use `OpenExistingVault` and report "not initialized" instead of git-initing a vault as a side effect. `initVault` writes a `.gitignore` (`.obsidian/`, `.DS_Store`, `*.tmp`) so editor/OS churn never becomes an owner-edit commit. MEM-01's message-existence check now requires `is_deleted = 0`. Node IDs containing path separators or `..` are rejected before any file IO (redirect_to traversal hardening). `memory status` excludes tombstones from type/tier counts and reports them on their own line.
- 2026-07-15 (correctness hardening, same day as creation): MEM-01 extended — a provenance lookup ERROR now propagates (window fails / situation skipped-and-logged) instead of being counted as a dropped ref; ingest logs its rejected-ref count. MEM-04 extended — shape-degenerate extractor replies (parsed episodes, all zero refs) freeze the watermark instead of advancing as "no episodes"; the message loader drains same-second chunk boundaries so `ts_unix` whole-second truncation can never skip messages; new `memory.max_window_messages` (default 200) splits oversized channel batches into sequential windows; authorless messages (no `users` row) are extracted with a raw-user_id author instead of being skipped forever; a fresh workspace without its singleton row reads watermark 0 instead of failing the run. The extractor prompt moved into the standard prompt store as `memory.extract_episodes` (user-customizable, versioned) and now carries the `prompts.Directive` language instruction from `digest.language`.
- 2026-07-15: file created with 5 contracts (MEM-01..05), all Enforced. Introduced by Secretary Memory Phases 0–2 (spec `docs/superpowers/specs/2026-07-15-secretary-memory-design.md`): a markdown+go-git memory vault at `WorkspaceDir()/memory` with a rebuildable SQLite index, mechanical entity seeding, situations ingest, a light-tier raw-text episode extractor (`memory.extract_episodes`), the `phaseMemory` daemon phase (after `phaseInbox`, off by default via `memory.enabled`), MCP read tools, and the `watchtower memory` CLI. Beliefs, rollup eviction, and dedupe are Phase 3+; injecting memory into existing pipelines is Phase 4.
