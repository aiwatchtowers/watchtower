# Digest-compare instrument fix: span-based episode selection + span coverage

**Date:** 2026-07-20
**Status:** approved by owner (design review in session; verdicts recorded in the 2026-07-20 memory.md changelog entry)
**Scope:** `internal/db/memory.go` (`ListEpisodesForChannelWindow`), `internal/memory/digest_compare.go`. Instrument-only: no schema change, no contract change, legacy pipeline untouched.

## Problem

The 2026-07-17 final validation blocked the render-inversion switch on "mean episode coverage 16%". The 2026-07-19 fresh compare (56 windows) showed the number is largely a **measurement artifact**, not an extraction gap:

- 29/56 windows read coverage **0%** while their stories WERE in the vault. Root cause: `ListEpisodesForChannelWindow` selects episodes by *refs-in-window* (`ts_unix > from AND ts_unix <= to`), but episodes cite only sparse key messages (live avg 3.8 refs over an avg multi-day story span, max span 26 days) while legacy digest windows are ~1–1.7 h sync-cycle slices. A window that falls between two cited key messages selects nothing — verified concretely on `wb-dev-cryptocard-project` 2026-07-17 10:07–11:04 (78 msgs, coverage 0, surrounded by episodes with refs 09:20–09:57 and 12:20–14:52 plus a 13-ref episode whose span contains the window).
- The metric itself counts only *exactly-cited* ts as covered, so even a perfectly-captured story window cannot approach 100% on a busy channel.
- Windows that did select episodes averaged 54%.

## Decisions (owner-approved)

1. **Span-based episode selection.** An episode is selected for a window when its story span `[MIN(ref ts), MAX(ref ts)]` (per channel) overlaps the window `(from, to]`:

   ```sql
   SELECT p.node_id FROM memory_provenance p
   JOIN memory_nodes n ON n.id = p.node_id
   WHERE p.channel_id = ? AND n.status != 'tombstone'
   GROUP BY p.node_id
   HAVING MIN(p.ts_unix) <= :to AND MAX(p.ts_unix) > :from
   ```

   Same exclusive-low / inclusive-high boundary discipline as today, signature unchanged, the compare runner is the only caller. Live fact: only `episode` nodes carry `memory_provenance` rows, so no rollup/entity mega-spans enter. A long-running story (max live span 26 days) intentionally matches every window it spans — stories outlive windows; that is the fix, not a bug.

2. **Span coverage metric.** A window message counts as covered when its ts falls inside ANY selected episode's span — "this part of the timeline is inside a story memory knows". Replaces the cited-ts metric (an artifact by construction; a perfect render never reaches 100%). Same `memory_digest_shadow.coverage` column, new semantics, no migration.

3. **Gap policy follows spans.** Raw gap messages fed to the render prompt are the messages OUTSIDE every selected span (previously: every not-exactly-cited message). In-span uncited messages are represented by the episode narrative; feeding them raw duplicated content and bloated the prompt. Consequence: the render's citable pool is episode provenance refs + out-of-span gap messages. The MEM-01 render-clause validation is untouched — only the offered gap set narrows.

4. **Report.** The per-channel Coverage column carries the new span semantics (explained in the report header); the Aggregate section gains `Windows with episodes: N/M` (the binary aggregate falls out of the span metric for free).

## Non-goals

- Switching digests off the legacy pipeline (separate slice, gated on re-running this instrument + owner hand-review).
- Daily/coarser compare windows — deferred; span selection addresses the root cause.
- Any change to episode extraction, `memory_provenance` population (MEM-02 untouched), or the legacy digest pipeline (MEM-05: compare stays a pure reader).

## Invariants preserved

- **MEM-01 render clause** (ex-MEM-13): every emitted ref still episode-cited or resolver-validated; invented refs dropped-and-counted. Guard tests unchanged.
- **MEM-05**: the compare writes only `memory_digest_shadow`; `TestDigestCompare_LegacyTablesByteIdentical` unchanged.
- A window with no overlapping episode still records a coverage-0 shadow row and makes NO generator call.

## Test plan (TDD)

- `internal/db`: span-selection query — episode with refs outside the window but span over it → selected; span not overlapping → not selected; tombstone → excluded; boundary cases at `from`/`to`.
- `internal/memory`: interval-based `splitCoverage` (in-span covered, out-of-span gap); `shadowRender` integration — a window strictly between two cited refs of a spanning episode renders with coverage > 0; a no-episode window stays coverage-0/no-call.
- Existing `TestMemory13_*` / `TestDigestCompare_*` pass unmodified.

## Validation

After merge: fresh `watchtower memory digest-compare --since 72h` on the live workspace; compare against the 2026-07-19 report (expectation: the 0%-window class collapses to genuinely-uncovered windows only; mean coverage becomes a truthful switch input); report goes to the owner for the go/no-go re-read.
