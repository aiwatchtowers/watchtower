# Secretary Memory (Phases 0–2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the memory vault (markdown + go-git), the rebuildable SQLite index, mechanical seeding, MCP read tools, and consolidation v1 (situations ingest + cheap-tier raw-text episode extractor) per `docs/superpowers/specs/2026-07-15-secretary-memory-design.md`.

**Architecture:** `internal/memory` package: vault (go-git) as source of truth → index reconcile into `watchtower.db` (FTS5) → resolver (ID/alias/redirect) → daemon phase `phaseMemory` (after `phaseInbox`): reconcile → seed → ingest situations → extract episodes (AI, light tier, write-time ts validation) → advance watermark → render `map.md`. MCP tools `memory_map`/`memory_open`/`memory_recall` read the result.

**Tech Stack:** Go 1.25, `modernc.org/sqlite` (FTS5 included), `github.com/go-git/go-git/v5` (new direct dep), `gopkg.in/yaml.v3` (promote to direct), goose migration, `internal/digest` Generator interface (mocked in tests).

## Global Constraints

- Module path `watchtower`, Go 1.25. Run `gofmt`, `go vet`, `go build ./...` and the affected package tests green before each commit; `golangci-lint run` before PR.
- **MEM-01:** no message ref is written to the vault unless it resolves against `messages` at write time. Dropped refs are counted, never repaired.
- **MEM-02:** dropping all `memory_*` tables + reindex reproduces the incrementally-maintained index.
- **MEM-03:** a dirty vault working tree is committed as a separate `memory(owner-edit)` commit before any machine write in the run.
- **MEM-04:** the watermark advances only alongside the commit of the corresponding chunk; crash between them re-processes (node-ID upsert idempotency), never skips.
- **MEM-05:** consolidation writes nothing to inbox tables and never touches `inbox_last_processed_ts`. INBOX-01..09 / DASH-01..04 untouched — do not modify `internal/inbox`.
- Every AI call goes through the standard tier routing: source tag `memory.extract_episodes` in BOTH `internal/digest/models.go` and `internal/codex/models.go` (light tier).
- New guard tests follow the inventory naming convention `TestMemoryNN_...`.
- All new docs in English.

## File Structure

- `internal/db/migrations/000NN_memory_index.sql` — memory_nodes/aliases/node_stats/FTS + `workspace.memory_last_extracted_ts` + `pipeline_runs.cache_read_tokens`/`cache_creation_tokens`; mirror in `schema.sql`.
- `internal/db/memory.go` (+`_test.go`) — index CRUD, alias resolution queries, stats bump, watermark get/set.
- `internal/memory/node.go` — Node struct, frontmatter, wiki-link parse.
- `internal/memory/vault.go` — go-git open/init, write+commit, owner-edit detection.
- `internal/memory/resolver.go` — Resolve(ref) with redirect chase.
- `internal/memory/index.go` — reconcile + full rebuild.
- `internal/memory/merge.go` — tombstone merge primitive.
- `internal/memory/seed.go` — mechanical entity skeletons.
- `internal/memory/ingest.go` — situations → episodes.
- `internal/memory/extract.go` — AI extractor + ts validation.
- `internal/memory/pipeline.go` — Run orchestration, chunking, map render, accounting.
- `internal/mcp/memory.go` (+`_test.go`) — three MCP tools.
- `cmd/memory.go` (+`_test.go`) — CLI subcommands.
- `internal/config/config.go` — `MemoryConfig`.
- `internal/daemon/daemon.go` — `phaseMemory`.
- `internal/digest/models.go`, `internal/codex/models.go` — tier routing.
- `docs/inventory/memory.md` — MEM-01..05; `docs/inventory/README.md` row; `CLAUDE.md` feature note; `docs/app-guide.md` section.

---

## Task 1: Migration — index tables, watermark, cache-token columns

**Files:** new `internal/db/migrations/000NN_memory_index.sql`; modify `internal/db/schema.sql`, `internal/db/migrations_test.go` (`TestAllTablesExist`), golden snapshot.

- [ ] **Step 1: failing test** — add `memory_nodes`, `memory_aliases`, `memory_node_stats` to `TestAllTablesExist`; add a column-presence assertion for `workspace.memory_last_extracted_ts` and `pipeline_runs.cache_read_tokens`/`cache_creation_tokens` in the migration test file (follow the pattern used by 00013 for `style_profile`).
- [ ] **Step 2:** `go test ./internal/db/ -run 'TestAllTablesExist|TestMigrations'` → FAIL (missing tables).
- [ ] **Step 3: implement** — goose Up per the spec's Data Model section (three tables + `CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED, title, body)` + two `ALTER TABLE ... ADD COLUMN`s + `workspace` column, all defaults NULL/0 so existing rows are untouched). Down drops tables and recreates nothing exotic (ALTER-added columns stay — note it in a comment, consistent with SQLite constraints and prior migrations' practice).
- [ ] **Step 4:** mirror into `schema.sql`, regenerate golden: `go test ./internal/db/ -run TestSchemaGolden -update`.
- [ ] **Step 5:** full `go test ./internal/db/` green. Commit `feat(db): memory index tables + consolidation watermark + split cache token columns`.

## Task 2: DB layer — `internal/db/memory.go`

**Interfaces:**

```go
type MemoryNodeRow struct { ID, Type, Tier, Status, RedirectTo, Title, Path, ContentHash, IndexedAt string }
func UpsertMemoryNode(db *DB, row MemoryNodeRow, body string, aliases []string) error // node+aliases+FTS in one tx
func DeleteMemoryNode(db *DB, id string) error
func LookupMemoryAlias(db *DB, ref string) (nodeID string, err error)                 // COLLATE NOCASE
func GetMemoryNode(db *DB, id string) (MemoryNodeRow, error)
func SearchMemoryFTS(db *DB, query string, limit int) ([]MemoryHit, error)
func BumpMemoryAccess(db *DB, id string) error
func MemoryWatermark(db *DB) (float64, error) / SetMemoryWatermark(db *DB, ts float64) error
func DropMemoryIndex(db *DB) error                                                    // for reindex
```

- [ ] **Step 1: failing tests** — round-trip upsert (aliases replaced atomically, FTS row replaced), alias case-insensitivity, FTS snippet search, watermark get/set against `workspace` (same shape as `inbox_last_processed_ts` accessors in `internal/db/inbox.go:415`).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** green; commit.

## Task 3: Node format — `internal/memory/node.go`

**Interfaces:**

```go
type Node struct {
    ID, Type, Tier, Status, RedirectTo, Title string
    Aliases []string
    Refs    struct{ PeopleCard int64; Targets []int64 }
    Body    string            // markdown below frontmatter, H1 included
}
func ParseNode(raw []byte) (Node, error)      // strict: unknown frontmatter keys preserved? NO — error (schema discipline)
func (n Node) Render() []byte                 // canonical render; Parse(Render(n)) == n
func (n Node) Links() []Link                  // [[id|label]] occurrences
func NewID(kind string) string                // ent_/ep_/sum_/bel_ + ULID
```

- [ ] **Step 1: failing tests** — parse/render round-trip (golden literal in test), H1 → Title extraction, link extraction incl. label-less `[[ep_x]]`, invalid type/tier rejected, ULID IDs sortable + prefixed.
- [ ] **Step 2–4:** FAIL → implement (yaml.v3 for frontmatter — promote to a direct require; `github.com/oklog/ulid/v2` or crypto/rand ULID impl — prefer the tiny dependency-free encode since we only need generate) → green; commit.

## Task 4: Vault — `internal/memory/vault.go` (go-git)

**Interfaces:**

```go
func OpenVault(path string) (*Vault, error)            // init repo + map.md on first run
func (v *Vault) ReadNode(id string) (Node, error)
func (v *Vault) WriteNodes(nodes []Node, msg CommitMsg) (commitHash string, err error)
func (v *Vault) DirtyWorktree() (bool, error)
func (v *Vault) CommitOwnerEdits() (bool, error)       // MEM-03; returns whether a commit was made
type CommitMsg struct{ Op, Summary, Cause string; NodeIDs []string }  // renders the structured message
```

- [ ] **Step 1: failing tests** — first-open initializes repo (`.git` exists, initial commit contains `map.md`); WriteNodes produces exactly one commit whose message first line is `memory(<op>): <summary>` and body lists node IDs + cause; **TestMemory03_OwnerEditsSeparateCommit**: hand-edit a file via os.WriteFile → `CommitOwnerEdits` commits it, subsequent `WriteNodes` commit contains only machine paths (assert via commit tree diff).
- [ ] **Step 2–4:** FAIL → implement with `go-git/v5` (worktree Add/Commit; author `watchtower <daemon@local>`) → green. `go mod tidy` (go-git direct). Commit.

## Task 5: Resolver — `internal/memory/resolver.go`

- [ ] **Step 1: failing tests** — resolve by canonical ID; by alias (case-insensitive; natural keys like `C0123ABC`, `situation:42`); tombstone chase across a 2-hop redirect chain returns final node + final ID; cycle (a→b→a) returns error, not hang; unknown ref → typed `ErrNotFound`.
- [ ] **Step 2–4:** FAIL → implement over `internal/db/memory.go` lookups + `vault.ReadNode` → green; commit.

## Task 6: Index reconcile + rebuild — `internal/memory/index.go`

```go
func Reconcile(v *Vault, db *db.DB) (Stats, error)  // hash-diff changed/new/deleted files
func Rebuild(v *Vault, db *db.DB) error             // DropMemoryIndex + Reconcile from empty
```

- [ ] **Step 1: failing tests** — edit a file → reconcile updates title/FTS/hash; delete a file → index row gone; **TestMemory02_ReindexEquivalence**: build index incrementally over 3 reconciles with edits between, dump all memory_* tables; Rebuild from scratch; dumps identical (ignoring `indexed_at`).
- [ ] **Step 2–4:** FAIL → implement → green; commit.

## Task 7: Merge primitive — `internal/memory/merge.go`

- [ ] **Step 1: failing tests** — `Merge(loser, winner)`: loser file becomes tombstone stub (`status: tombstone`, `redirect_to`, body one line), loser's aliases present on winner (frontmatter AND index), winner body gains `merged from [[<loser>]]` line, exactly one commit, resolver now resolves old aliases to winner; merging a tombstone or into a tombstone → error.
- [ ] **Step 2–4:** FAIL → implement → green; commit.

## Task 8: Seeding — `internal/memory/seed.go`

Mechanical, no AI. Sources: `users` (people with ≥ `seed_min_messages` messages in last 30d, joined to `people_cards` when present), `channels` (with any text in 30d), `jira` project keys (even while sync is dead — aliases ready).

- [ ] **Step 1: failing tests** — seeded person node: H1 = display name, aliases contain slack user ID (+email when known), `refs.people_card` set, `tier: long`, sections What/Current/Facts/Links/Open loops present (What filled from people_card title/summary line when available); channel node aliases contain channel ID; idempotency: second run creates nothing (assert node count + no new commit); threshold respected.
- [ ] **Step 2–4:** FAIL → implement (one commit `memory(seed): N entities`) → green; commit.

## Task 9: Tier routing for `memory.extract_episodes`

- [ ] **Step 1: failing tests** — add `"memory.extract_episodes"` to the light-tier lists in `internal/digest/models_test.go` and `internal/codex/models_test.go` (same pattern as `catchup.peel` in the catchup plan).
- [ ] **Step 2–4:** FAIL → add to both `ModelForSource` switches → green; commit.

## Task 10: Extractor — `internal/memory/extract.go`

```go
type extractedEpisode struct {
    Title, Story string
    Outcome      *string
    Participants []string
    Refs         []struct{ ChannelID, TS string }
    EntityHints  []string
}
func buildExtractPrompt(ch channelWindow) (system, user string)
func parseExtract(raw string) ([]extractedEpisode, error)
func validateRefs(db *db.DB, eps []extractedEpisode) (kept []extractedEpisode, dropped int)
```

- [ ] **Step 1: failing tests** —
  - prompt contains real `[ts] author: text` lines and the copy-don't-invent instruction; running_summary line included when present.
  - parser: fenced/unfenced JSON, empty array, garbage → error.
  - **TestMemory01_HallucinatedRefsDropped**: fixture episodes where one ref resolves (seeded `messages` row) and one has a year-shifted ts → kept episode has 1 ref, dropped==1; an episode whose refs ALL fail is discarded entirely (kept slice shorter), counted.
- [ ] **Step 2–4:** FAIL → implement (validation = `SELECT 1 FROM messages WHERE channel_id=? AND ts=?`) → green; commit.

## Task 11: Situations ingest — `internal/memory/ingest.go`

- [ ] **Step 1: failing tests** — open situation → episode node created: `tier: short`, `status: active`, alias `situation:<id>`, Story = situation chronology, provenance = its inbox-item message refs **re-validated** (a seeded bad ref is dropped — MEM-01 applies here too); second run on unchanged situation → no new node, no commit; situation transitions to done → same node finalized (`status: closed`, `tier: long`, Outcome from resolved_reason); converted → Outcome mentions target/track link. No writes to any inbox/situation table (assert row-identical before/after — **TestMemory05_InboxUntouched**).
- [ ] **Step 2–4:** FAIL → implement → green; commit.

## Task 12: Pipeline — `internal/memory/pipeline.go` + config

```go
type Pipeline struct { db *db.DB; vault *Vault; generator digest.Generator; cfg config.MemoryConfig; logf func(...) }
func (p *Pipeline) Run(ctx context.Context) (RunStats, error)
```

Order per run: Reconcile (+MEM-03 owner-edit commit) → Seed → Ingest → Extract (chunked by `max_chunk_messages`, per-channel windows, AI via `p.generator.Generate(digest.WithSource(ctx, "memory.extract_episodes"), ...)`) → SetMemoryWatermark per fully-processed window → render `map.md` → finalize `pipeline_runs` row (`pipeline='memory'`, cache columns split).

- [ ] **Step 1: failing tests** (fake Generator) —
  - happy path: N fixture messages over 2 channels → episodes committed, watermark == last processed ts, map.md lists new entities/episodes, pipeline_runs row done with token fields.
  - **TestMemory04_WatermarkFreezeOnAIFailure**: generator errors on channel 2 → channel 1's episodes committed, watermark == end of channel 1's window (never past channel 2), run status still `done` with error noted in step row (isolation, catchup-style).
  - chunk cap respected (only first `max_chunk_messages` consumed; debt remains).
  - disabled config → Run is a no-op.
  - AI failure never rolls back Reconcile/Seed/Ingest commits.
- [ ] **Step 2: config** — `MemoryConfig{Enabled bool; MaxChunkMessages, SeedMinMessages, MaxEpisodesPerWindow int}` in `internal/config/config.go` with viper defaults (false / 2000 / 20 / 5) + config test.
- [ ] **Step 3–5:** FAIL → implement → green; commit.

## Task 13: Daemon phase

- [ ] **Step 1: failing test** — daemon test (pattern of existing phase tests in `internal/daemon/daemon_test.go`): with memory enabled, `phaseMemory` runs after `phaseInbox` and before `phaseNextStep`; disabled → not invoked; `inbox_last_processed_ts` unchanged by the phase.
- [ ] **Step 2–4:** FAIL → wire `d.phaseMemory(ctx)` in `daemon.Run` (sequential, after `d.phaseInbox(ctx)`) with the standard panic-guard/logging wrapper used by other phases → green. Check the daemon coverage floor (recently lowered to 70 — keep it satisfied). Commit.

## Task 14: MCP tools — `internal/mcp/memory.go`

- [ ] **Step 1: failing tests** (pattern of `internal/mcp/people_test.go`) — `memory_map` returns map.md content + counts; `memory_open` resolves alias → canonical, bumps `memory_node_stats`; opening via a tombstoned old ID returns winner + its current id in the payload; `memory_recall` returns FTS hits with alias exact-match ranked first and does NOT bump stats.
- [ ] **Step 2–4:** FAIL → register three tools in `server.go` alongside existing ones → green; commit.

## Task 15: CLI — `cmd/memory.go`

- [ ] **Step 1: failing tests** — `watchtower memory status` (counts, watermark, debt estimate), `memory reindex` (calls Rebuild), `memory open <ref>`, `memory recall <q>`, `memory consolidate --once` (respects enabled=false with a clear message), `memory seed --dry-run` (prints would-create list, writes nothing).
- [ ] **Step 2–4:** FAIL → implement (cobra, existing cmd patterns; factory seam for pipeline like `newDayPlanPipelineFactory`) → green; commit.

## Task 16: Inventory + docs

- [ ] Write `docs/inventory/memory.md`: MEM-01..05 with guard-test names (`TestMemory01_...` etc.), changelog entry; add the module row to `docs/inventory/README.md`.
- [ ] `CLAUDE.md`: short feature note (vault location, "files+git primary / SQLite index derived", the five contracts, off-by-default flag).
- [ ] `docs/app-guide.md`: user-facing section (what memory is, where the vault lives, Obsidian compatibility, CLI commands).
- [ ] Commit `docs(memory): inventory contracts + guides`.

## Self-Review

- [ ] `gofmt ./... && go vet ./... && go build ./... && go test ./...` green; `golangci-lint run` clean; sentrux baseline unchanged or refreshed intentionally.
- [ ] Manual E2E on a dev workspace: enable → `memory consolidate --once` twice → open vault in Obsidian (links + aliases resolve) → hand-edit an entity file → next run produces a separate `memory(owner-edit)` commit → `memory reindex` → MCP inspector: map/open/recall.
- [ ] Grep check: no writes to inbox tables from `internal/memory` (`grep -rn "inbox_" internal/memory/` shows reads only).
- [ ] Run `/local-review` before PR.
