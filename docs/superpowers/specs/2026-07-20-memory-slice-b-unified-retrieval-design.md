# Secretary Memory — Slice B: Unified Retrieval (Importance × Relevance): Design Spec

> Date: 2026-07-20. Status: direction CONFIRMED by the owner (2026-07-20). Second of four planned slices in the memory-retrieval redesign brainstormed 2026-07-18 (Slice A: importance-score foundation, shipped on `feature/memory-phase5`/PR #40; Slice C: chat/Swift; Slice D: meta-layer + navigation — both not yet designed).
> Background: Slice A added a persisted, queryable `memory_nodes.importance_score`, refreshed by `Reconcile`/`Rebuild`, but nothing reads it for ranking yet. Today `memory_recall` (MCP tool), the daily briefing's "Memory revisions" journal, and meeting-prep's attendee context each select and rank memory content with a different, unrelated ad hoc heuristic — pure FTS5 `rank`, an unranked notability-diff filter, and `ORDER BY confidence DESC` respectively. Slice B unifies the *ranking mechanism* (not the API surface) across all three, and replaces each legacy path only after the owner (via this session) verifies the new ranking against real production data.

## Concept

One shared primitive — importance × relevance — replaces three unrelated ranking heuristics. Rather than a single mega-function forcing three structurally different selection problems (free-text search, subject lookup, temporal-delta filtering) into one signature, Slice B introduces:

1. **`RankByImportance`** — the only place weight and relevance combine, consumed by three focused retrieval functions.
2. **Three retrieval functions**, each computing its own relevance signal for its own selection problem, then delegating final ranking to the shared primitive.
3. **A schema extension** (`memory_provenance.sender_id`) needed for one of the three (subject-based short-term context) to work without a runtime join back to raw messages.
4. **A dark compare-mode** (this repo's established pattern for replacing live behavior, see `digest_compare.go`) with a twist: verification against real production data and the legacy-to-new switch are both *part of this slice*, not deferred to a later one — contingent on the evidence, not automatic.

## Design

### 1. `RankByImportance` — the shared primitive

New file `internal/memory/retrieve.go`:

```go
// ScoredCandidate pairs an indexed node with a caller-computed relevance
// signal (0..1, semantics owned by the caller) for one RankByImportance call.
type ScoredCandidate struct {
    Row       db.MemoryNodeRow
    Relevance float64
}

// RankByImportance is the ONE place importance_score and relevance combine:
// score = Row.ImportanceScore * Relevance, sorted descending, truncated to
// limit. Every retrieval function in this package funnels its own relevance
// signal through this single combiner instead of inventing its own ranking.
func RankByImportance(candidates []ScoredCandidate, limit int) []db.MemoryNodeRow
```

Nodes with `ImportanceScore == 0` (no override, no organic signal yet — the common case for a freshly-seeded entity) score `0` regardless of relevance and sort last; this is an accepted characteristic, not a bug — a brand-new, untouched node genuinely has no importance signal yet.

### 2. `RetrieveByQuery` — replaces `memory_recall`'s ranking

```go
func RetrieveByQuery(database *db.DB, query string, limit int) ([]db.MemoryNodeRow, error)
```

Reuses `SearchMemoryFTS`'s existing sanitization and FTS5 `MATCH`, but drops `ORDER BY rank` in favor of fetching a wider candidate window (e.g. `limit * 4`, capped) ranked by FTS `rank` alone, then re-ranking that window through `RankByImportance` with `Relevance` derived from each row's normalized `rank` (bm25 is unbounded and smaller-is-better; normalize via `1 / (1 + rank)` or an equivalent monotonic transform into `(0, 1]`). The existing alias-exact-match short-circuit (`memory_recall`'s current behavior — an exact alias hit always ranks first) is preserved unchanged, prepended ahead of the ranked FTS window.

### 3. `RetrieveBySubject` — replaces meeting-prep's ad hoc selection

```go
func RetrieveBySubject(database *db.DB, subjects []string, limitLong, limitShort int) (longTerm, shortTerm []db.MemoryNodeRow, err error)
```

- `longTerm`: beliefs with `subject IN (subjects)` and `status IN ('active','shaken')`, `Relevance = 1.0` (exact subject match — there is no partial-match notion here), ranked by `RankByImportance` (replacing today's `ORDER BY confidence DESC`).
- `shortTerm`: short-tier episodes found via the new `ListShortTierEpisodesForAliases` (§4), ranked by recency (`ts_unix DESC`), not importance — a short-tier episode's value here is "what's recently happened," not "how important is this in general."

### 4. `RetrieveRevisions` — replaces briefing's selection

```go
func RetrieveRevisions(database *db.DB, sinceTS float64, limit int) ([]db.MemoryNodeRow, error)
```

Keeps the existing `notableRevision` filter (status transition, or `|confidence delta| >= 0.2`) as the candidate gate — unchanged, since that logic correctly identifies *what counts as a notable change* and Slice B does not revisit it. What changes: candidates are no longer capped in encounter order. `Relevance` = the notable revision's confidence-delta magnitude (status transitions get `Relevance = 1.0`, unconditionally notable), then `RankByImportance` orders the result so a notable change on a high-importance belief surfaces before the same-magnitude change on a low-importance one.

### 5. Schema: `memory_provenance.sender_id`

New migration (additive, no CHECK/table-recreation dance, matching the `00027` precedent):

```sql
ALTER TABLE memory_provenance ADD COLUMN sender_id TEXT NOT NULL DEFAULT '';
CREATE INDEX idx_memory_provenance_sender ON memory_provenance(sender_id);
```

Populated only for schemes with a genuine per-message sender: Slack (`messages.user_id`, looked up by the existing `(channel_id, ts)` primary key) and Gmail (`gmail_messages.from_email`, looked up by message id). Left `''` for `cal:`/`chat:`/`act:` schemes — calendar's organizer is a weaker analogue and chat/act refs are always owner-authored (no discriminating value). `provenanceRows` (`internal/memory/dedupe.go`) gains a `senderResolver` parameter (mirroring the existing `messageChecker` seam in `provenance.go`); every call site already carries a `*db.DB` to construct it from. No migration-time backfill — matching Slice A's `importance_score` precedent, `memory_provenance` is fully vault-derived and converges via `Reconcile`/`watchtower memory reindex`.

New query, `internal/db/memory.go`:

```go
// ListShortTierEpisodesForAliases returns short-tier episode ids whose
// memory_provenance.sender_id matches one of aliases, ordered by recency.
func (db *DB) ListShortTierEpisodesForAliases(aliases []string, limit int) ([]MemoryNodeRow, error)
```

### 6. Consumer wiring (dark, behind three independent flags)

`memory.retrieve.recall_compare`, `memory.retrieve.meeting_prep_compare`, `memory.retrieve.briefing_compare` — each `false` by default, matching this repo's dark-launch convention.

Mirrors `digest_compare.go`: each flagged surface, when enabled, runs the LEGACY selection (unchanged, still authoritative) and the NEW retrieval function side by side, writes both plus a diff to a new `memory_retrieve_shadow` table (`surface, old_result_json, new_result_json, diff_metrics_json, ts`), and leaves the real response untouched. `watchtower memory retrieve-compare [--since --out]` runs it on demand and writes a branch report, mirroring `digest-compare`.

Per-surface diff metrics (objective, not subjective):
- **`memory_recall`**: mean `importance_score` of new top-N vs old top-N; coverage (does new's top-N still contain everything old's top-N found for the same query, i.e. no silent loss of exact-keyword hits).
- **meeting-prep**: is the belief set old found a subset of new's (new must not drop anything, only reorder/add); does `shortTerm` add plausible, on-topic episodes (spot-checked, not purely automatic).
- **briefing**: intersection of old vs new top-5 notable-revision sets; whether reordering by importance demonstrably promotes a higher-importance belief over a lower one at the same notability magnitude.

### 7. Verification and switch — part of this slice, evidence-gated

Unlike the `digest_compare` precedent (where switching legacy off is explicitly a later, separately-gated slice), this slice's LAST task is: run `retrieve-compare` against a safe, read-only snapshot of real production data (already taken: `/private/tmp/.../slice-b-verify/watchtower-snapshot.db` + cloned vault, sourced from the live `whitebit` workspace — 2,062 memory nodes, 465k messages — via `sqlite3 .backup`, never touching the live daemon's database), analyze the objective diff metrics above, and present them plainly. **Only if the metrics show new is not worse and demonstrably better on at least one dimension per surface** does this slice's final task retire the legacy selection code and make the new retrieval function sole-authoritative for that surface. If the evidence is ambiguous for a given surface, that surface's flag stays dark and the switch is deferred — surfaces are decided independently, not as an all-or-nothing bundle.

## Non-Goals

- Swift/chat's own `relevantMemory` query — Slice C's remit. Chat's *live* MCP tool-calling path (`memory_recall`) benefits automatically once `RetrieveByQuery` replaces its ranking, with no Slice C work required.
- Any new node type, meta-layer, or owner-facing UI — Slice D's remit.
- Revisiting `notableRevision`'s notability rule itself (what counts as "notable") — only its ranking, once notable.
- A general-purpose plugin/selector architecture for hypothetical future retrieval needs — three known callers get three known functions (YAGNI).

## Test plan

- `RankByImportance`: pure unit tests (zero-importance sorts last, ties broken by original order stability, limit truncation).
- Each retrieval function: real SQLite-backed tests against a seeded test vault/DB, mirroring Slice A's test idiom (`newTestVault`/`newTestDB`/`writeNodes`).
- `ListShortTierEpisodesForAliases` + `sender_id` population: a DB-layer round-trip test per scheme (Slack populates, Gmail populates, cal/chat/act stay empty).
- Compare-mode: a `TestDigestCompareLegacyTablesByteIdentical`-style guard proving the dark path never mutates the legacy tables/response, mirroring the existing `digest_compare` precedent.
- Real-data verification: not an automated test — a one-time, human-readable report from running `retrieve-compare` against the WhiteBit snapshot, reviewed as part of this slice's final task before any switch.

## Rollout

Lands on its own branch, same discipline as Slice A (own branch, own PR, subagent-driven-development execution). Depends on Slice A's `importance_score` (already shipped, PR #40 — may or may not be merged into `main` by the time this starts; branch from whichever is current, following the same precedent Slice A's Task 0 established if PR #40 is still open).
