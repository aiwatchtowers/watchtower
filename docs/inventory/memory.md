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

**Observable:** No message reference is ever written to the vault unless it resolves against the local `messages` table at write time (`SELECT 1 FROM messages WHERE channel_id=? AND ts=?`). A ref the extractor invented — a year-shifted ts, a wrong channel — is dropped and counted (`refs_rejected`), never "fixed up" to a nearby real message. An episode whose refs *all* fail validation is discarded entirely, not written ref-less. The same re-validation applies to situation ingest: signal message refs are checked again before being copied into an episode's `## Provenance` section, even though detector-written refs resolve 100% in practice.

**Why locked:** Provenance is the memory's trust anchor — every fact in the vault is supposed to link back to a real message the owner can open. One hallucinated link that 404s in Slack poisons trust in every other link; silently repairing refs would be worse, attributing a claim to a message that never said it. Drop-and-count keeps the vault verifiable and makes extractor hallucination measurable instead of invisible.

**Test guards:**
- `internal/memory/extract_test.go::TestMemory01_HallucinatedRefsDropped`

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

**Why locked:** The watermark only ever moves forward, so any window it skips is lost to memory forever. Advancing on failure would mean a transient model error silently drops a day of history from the vault with no way to notice; freezing trades a cheap re-extraction for zero lost windows — the same freeze discipline INBOX-09 established for the inbox watermark.

**Test guards:**
- `internal/memory/pipeline_test.go::TestMemory04_WatermarkFreezeOnAIFailure`

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
- **Access-stats bump is best-effort.** `memory_open` bumps `memory_node_stats` with an ignored error: under a read-only (query_only) MCP session the write fails and the open must still return the node. Stats are telemetry that under-counts in read-only contexts; nothing may start depending on their accuracy.
- **Failed-window re-extraction can duplicate episodes.** Per MEM-04, a failed window is re-extracted next run — but extracted episodes get fresh ULIDs, so a window that partially succeeded before failing (or a crash between vault commit and watermark write) can produce near-duplicate episode nodes. Deduplication against prior extractions and situation coverage is deliberately deferred to Phase 3; until then duplicates are accepted, not a bug to hack around at write time.

## Changelog

- 2026-07-15: file created with 5 contracts (MEM-01..05), all Enforced. Introduced by Secretary Memory Phases 0–2 (spec `docs/superpowers/specs/2026-07-15-secretary-memory-design.md`): a markdown+go-git memory vault at `WorkspaceDir()/memory` with a rebuildable SQLite index, mechanical entity seeding, situations ingest, a light-tier raw-text episode extractor (`memory.extract_episodes`), the `phaseMemory` daemon phase (after `phaseInbox`, off by default via `memory.enabled`), MCP read tools, and the `watchtower memory` CLI. Beliefs, rollup eviction, and dedupe are Phase 3+; injecting memory into existing pipelines is Phase 4.
