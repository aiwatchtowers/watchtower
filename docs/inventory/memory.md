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

"Failure" includes shape-degenerate extractor replies: JSON that parses but whose episodes ALL carry zero refs (a misnamed `refs` key, wrong nesting) fails the window and freezes the watermark exactly like an AI error — it is never read as routine chatter. A genuinely empty `[]` remains a clean no-episode window and advances. Shape-degenerate episodes are counted (`RunStats.Malformed`).

Whole-second safety: `messages.ts_unix` is truncated to whole seconds, so the message loader (`ListMemoryExtractMessages`) drains the chunk boundary — when the chunk cap cuts inside a second, ALL rows sharing that second are loaded (slightly exceeding the cap) so the watermark second is always fully processed and the strict `ts_unix > watermark` reload can never permanently skip same-second rows.

Window bounding: one window holds at most `memory.max_window_messages` messages (default 200); a busier channel forms multiple sequential windows in the same run, so a single poison window cannot blow the model context or stall the whole channel at full cost. A later window of a channel never advances the watermark past an earlier failed window of the same channel.

**Why locked:** The watermark only ever moves forward, so any window it skips is lost to memory forever. Advancing on failure would mean a transient model error silently drops a day of history from the vault with no way to notice; freezing trades a cheap re-extraction for zero lost windows — the same freeze discipline INBOX-09 established for the inbox watermark. The same reasoning covers degenerate-shape replies (a schema drift would otherwise silently discard every episode while looking like healthy chatter) and same-second truncation (a chunk cut inside one busy second would silently drop the rest of that second forever).

**Test guards:**
- `internal/memory/pipeline_test.go::TestMemory04_WatermarkFreezeOnAIFailure`
- `internal/memory/pipeline_test.go::TestMemory04_ShapeDegenerateJSONFreezesWatermark`
- `internal/memory/pipeline_test.go::TestMemory04_SameSecondChunkCapNeverSkips`
- `internal/memory/pipeline_test.go::TestMemory04_InterleavedWindowFreeze`
- `internal/memory/pipeline_test.go::TestMemory04_LaterWindowNeverPassesEarlierFailedWindow`

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
- **MEM-03 has a crash window.** The owner-edit commit is not atomic with the machine writes that follow: if the process is killed between a machine file write and its commit, those machine-written files sit uncommitted in the worktree and the NEXT run's `CommitOwnerEdits` sweeps them into a `memory(owner-edit)` commit — machine text mislabeled as the owner's. Rare (requires a kill inside a narrow window) and self-limiting, but `git log` attribution is not crash-proof; do not present it as such, and do not "fix" it casually — a proper fix needs a staging/journal step.
- **Phase 4 must frame vault text as model-mediated.** Episode bodies (and future entity rewrites) are AI summaries of third-party messages — model-mediated hearsay with provenance links, not the owner's own notes. The Phase 4 injection spec (working-memory blocks, Discuss tools) must present vault content to downstream prompts as such ("memory notes derived from Slack/Jira", never "the owner wrote"); only `memory(owner-edit)` commits carry owner-asserted text.
- **Failed-window re-extraction can duplicate episodes.** Per MEM-04, a failed window is re-extracted next run — but extracted episodes get fresh ULIDs, so a window that partially succeeded before failing (or a crash between vault commit and watermark write) can produce near-duplicate episode nodes. Deduplication against prior extractions and situation coverage is deliberately deferred to Phase 3; until then duplicates are accepted, not a bug to hack around at write time.
- **Boundary drain can exceed the chunk cap.** When `memory.max_chunk_messages` cuts inside one busy second, the loader intentionally loads the whole second (see MEM-04), so a run may consume slightly more than the cap — bounded by one second of traffic. The per-window cap (`memory.max_window_messages`) still bounds each individual prompt.
- **Malformed count is run-level only.** Shape-degenerate episode counts surface in `RunStats.Malformed` and logs; `pipeline_steps` has no dedicated column for them (the failed window's step row carries `status='error'`). Adding a column is a schema change deferred until the count proves useful.
- **Authorless messages fall back to the raw user_id.** Messages whose author has no `users` row (deleted/ex-employee, never synced) are extracted with the Slack user ID as the author label — the extractor sees `U0ABC123:` instead of a display name until the user table catches up.

## Changelog

- 2026-07-15 (infrastructure hardening, review batch B): cross-process `memory.lock` (flock in the workspace dir, digest-pipeline precedent) taken by `Pipeline.Run` and CLI seed/reindex — contention returns "another memory run is in progress" (CLI prints, daemon logs and skips the cycle). `Reconcile` gained quarantine semantics: a per-file parse/upsert failure (Obsidian damage, unknown frontmatter key, duplicate alias) is skipped-and-counted (`Stats.Quarantined` + paths, warning logged), the file stays in the on-disk set so its existing index row is preserved; only IO/DB-wide failures error the pass. Read-only CLI subcommands (`memory open`, `memory reindex`) use `OpenExistingVault` and report "not initialized" instead of git-initing a vault as a side effect. `initVault` writes a `.gitignore` (`.obsidian/`, `.DS_Store`, `*.tmp`) so editor/OS churn never becomes an owner-edit commit. MEM-01's message-existence check now requires `is_deleted = 0`. Node IDs containing path separators or `..` are rejected before any file IO (redirect_to traversal hardening). `memory status` excludes tombstones from type/tier counts and reports them on their own line.
- 2026-07-15 (correctness hardening, same day as creation): MEM-01 extended — a provenance lookup ERROR now propagates (window fails / situation skipped-and-logged) instead of being counted as a dropped ref; ingest logs its rejected-ref count. MEM-04 extended — shape-degenerate extractor replies (parsed episodes, all zero refs) freeze the watermark instead of advancing as "no episodes"; the message loader drains same-second chunk boundaries so `ts_unix` whole-second truncation can never skip messages; new `memory.max_window_messages` (default 200) splits oversized channel batches into sequential windows; authorless messages (no `users` row) are extracted with a raw-user_id author instead of being skipped forever; a fresh workspace without its singleton row reads watermark 0 instead of failing the run. The extractor prompt moved into the standard prompt store as `memory.extract_episodes` (user-customizable, versioned) and now carries the `prompts.Directive` language instruction from `digest.language`.
- 2026-07-15: file created with 5 contracts (MEM-01..05), all Enforced. Introduced by Secretary Memory Phases 0–2 (spec `docs/superpowers/specs/2026-07-15-secretary-memory-design.md`): a markdown+go-git memory vault at `WorkspaceDir()/memory` with a rebuildable SQLite index, mechanical entity seeding, situations ingest, a light-tier raw-text episode extractor (`memory.extract_episodes`), the `phaseMemory` daemon phase (after `phaseInbox`, off by default via `memory.enabled`), MCP read tools, and the `watchtower memory` CLI. Beliefs, rollup eviction, and dedupe are Phase 3+; injecting memory into existing pipelines is Phase 4.
