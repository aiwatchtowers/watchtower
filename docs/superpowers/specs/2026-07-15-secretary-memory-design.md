# Secretary Memory — Design Spec

> Date: 2026-07-15. Branch: `feature/secretary-memory`.
> Background: `docs/specs/memory-design-notes.md` (concept brainstorm) and `docs/specs/memory-data-audit.md` (live-data audit that settled episode sources and economics). This spec covers **Phases 0–2** in implementable detail; Phases 3–4 are outlined as follow-ups and get their own specs.

## Context

Watchtower distills a raw Slack/Jira/Calendar stream into digests, situations, tracks, and people cards, but the secretary has no *memory*: no durable, navigable "what I know about this world" layer. The design notes define one — a human-memory-inspired store (episodes / entities / rollups / beliefs, short-term vs long-term tiers, consolidation as sleep). The live-data audit confirmed feasibility (raw text ≈50K tokens/day; first-wave vocabulary ≈ hundreds of entities) and settled the inputs: situations are ready-made episodes; digests are background only (hallucinated links); a cheap-tier extractor reads raw text directly.

First-iteration consumers are **AI chats and MCP only**. Triage/compose pipelines do not read memory; all INBOX-* and DASH-* contracts stay untouched.

## Goals (Phases 0–2)

1. A memory vault: markdown nodes under git (go-git, no system binary), with stable IDs, aliases, and wiki-links — openable in Obsidian but never requiring it.
2. A rebuildable SQLite index over the vault: FTS5 recall, alias resolution, node stats.
3. MCP read path: `memory_map`, `memory_open`, `memory_recall` — plus the same access from Go code for future chat use.
4. Mechanical seeding: skeleton entity pages for active people/channels/projects from natural keys (no AI).
5. Consolidation v1 (episodes only): ingest situations as-is; extract episodes from raw text via a new cheap-tier prompt; debt-driven chunked runs, one git commit per chunk.
6. Provenance discipline: every message link written to the vault is validated against the local DB at write time.

## Non-Goals (Phases 0–2)

- Beliefs, hysteresis/shaken, revision journal in briefings, dispute situations, reflection (Phases 3–4).
- Injecting memory into Discuss chat or any existing pipeline prompt (Phase 4).
- Bot stream parsing (73% of messages; deterministic parser someday, never an LLM), Gmail input (not synced yet), Jira input (sync dead since 2026-04-24 — fix first).
- Embeddings/vector search. FTS5 + navigation only.
- Any Desktop UI. CLI + MCP + vault files are the whole surface for now.
- Obsidian integration beyond file-format compatibility.

## High-Level Architecture

```
                    ┌───────────────────────────────┐
   situations ──────►                               │
                    │  internal/memory              │   go-git commits
   messages ──chunk─►  Consolidation (daemon phase) ├──► vault (markdown+git)
                    │                               │        │
   prompts:         └───────────────────────────────┘        │ reconcile on run
   memory.extract_episodes (cheap tier)                      ▼
                                                     SQLite index (rebuildable)
                                                     memory_nodes/aliases/stats + FTS5
                                                              │
                                     MCP: memory_map / memory_open / memory_recall
```

- **Vault** = source of truth for node text and history. Lives at `Config.WorkspaceDir()/memory/` (`~/.local/share/watchtower/{workspace}/memory/`), a plain git repo managed via go-git.
- **Index** = derived state in the main `watchtower.db`. Droppable and rebuildable from the vault at any time.
- **Consolidation** = a daemon phase, debt-driven (watermark), chunked, one commit per chunk.

## Vault Format

### Layout

```
memory/
  .git/
  map.md                    # root world map (mechanical render in v1)
  entities/ent_<ulid>.md
  episodes/ep_<ulid>.md
  rollups/sum_<ulid>.md
  beliefs/bel_<ulid>.md     # empty dir until Phase 3
```

File name = node ID (stability under rename; Obsidian resolves `[[ent_x]]` to `ent_x.md`). Display name = H1 + aliases.

### Frontmatter (YAML)

```yaml
---
id: ent_01J2ZK...        # canonical, immutable
type: entity             # entity | episode | rollup | belief
tier: long               # short | long
status: active           # active | closed (episodes) | tombstone
redirect_to: ent_...     # tombstones only
aliases: ["billing-v2", "C0123ABC", "PROJX"]   # slugs + natural keys, one flat list
refs:                    # optional links into the relational world
  people_card: 42
  targets: [7, 13]
---
```

Rules:
- Frontmatter carries **authored** state only. Derived numbers (access_count, retention, FTS) live in the index, never in files.
- Natural keys (Slack channel ID, Slack user ID, Jira project key, email) are ordinary aliases — cross-source identity = several natural keys on one node.
- Body is markdown; internal links are `[[<id>|<label>]]`. Labels may go stale; consolidation refreshes them when it rewrites the page.
- Episodes carry a `## Provenance` section: bullet list of `channel_id + message ts` (+ permalink when known). Only validated references may be written (MEM-01 below).

### Node bodies (v1 templates)

- **Entity** (`entities/`): H1 name; `## What` (one paragraph); `## Current` (short, freely rewritten); `## Facts` (bullet prose with provenance markers); `## Links` (wiki-links to related nodes); `## Open loops` (links to targets/situations). Skeleton pages from seeding contain H1, What (mechanical: channel topic/purpose, person title from people_card), and empty sections.
- **Episode** (`episodes/`): H1 title; time range + participants line; `## Story` (summary; for situation-ingested episodes: the situation chronology as-is); `## Outcome`; `## Provenance`.
- **Rollup** (`rollups/`): H1 = period + scope; bullet lines of collapsed episodes with their provenance kept. Created by eviction, which is **out of scope until Phase 3** — the type and template exist, nothing writes them in v1–2.

## Data Model (index)

New goose migration `000NN_memory_index.sql` (see `add-migration` skill; mirror into `schema.sql`, add tables to `TestAllTablesExist`, regenerate golden):

```sql
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,             -- ent_*/ep_*/sum_*/bel_*
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone')),
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,                -- vault-relative file path
    content_hash  TEXT NOT NULL,                -- sha256 of file bytes at last index
    indexed_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_aliases (
    alias    TEXT PRIMARY KEY COLLATE NOCASE,
    node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
);

CREATE TABLE IF NOT EXISTS memory_node_stats (
    node_id          TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    access_count     INTEGER NOT NULL DEFAULT 0,
    last_accessed_at TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
    id UNINDEXED, title, body
);
```

Watermark + run accounting reuse existing machinery: a `sync_state`-style key for the message watermark (`memory_last_extracted_ts`) and per-situation ingest marks (see Consolidation), runs logged to `pipeline_runs`/`pipeline_steps` with cache_read and cache_creation **written separately** (audit consequence #8; extend the runs schema in the same migration with the two columns, nullable, backfilled NULL).

Journal = git log. No journal table. Reflection (Phase 4) reads commits.

## internal/memory Package

```
internal/memory/
  vault.go        # open/init repo (go-git), read/write nodes, commit(message, files)
  node.go         # Node struct, frontmatter parse/render (gopkg.in/yaml.v3), link parsing
  resolver.go     # Resolve(anyRef) -> canonical Node (alias → id → redirect chase)
  index.go        # reconcile(vault, db): diff content hashes vs HEAD, upsert index+FTS
  seed.go         # mechanical skeleton pages from people/channels/jira tables
  ingest.go       # situations → episodes (mechanical)
  extract.go      # raw-text episode extractor (AI, cheap tier) + ts validation
  pipeline.go     # Run(ctx): reconcile → seed-new → ingest → extract, chunked
```

Key behaviors:

- **`vault.Open`**: creates dir + `git init` + empty `map.md` on first run. All writes go through the vault type; every logical operation ends in exactly one commit with a structured message: first line `memory(<op>): <summary>`, body lists node IDs and cause (`run:<pipeline_run_id>` | `owner-edit` | `seed`).
- **Owner-edit detection (MEM-03)**: at the start of every run, if the working tree differs from HEAD, commit the diff *first* as `memory(owner-edit): manual changes` before any machine writes. Machine writes never mix into that commit.
- **`resolver.Resolve`**: accepts canonical ID, any alias (case-insensitive), or a tombstone ID; follows `redirect_to` chains (index-backed, cycle-guarded); returns the canonical node + its current ID.
- **`index.reconcile`**: compares `content_hash` of files against `memory_nodes`; re-parses changed files; rebuild-from-scratch is the same code path with an empty table (`watchtower memory reindex`).
- **Merge** (used by consolidation later; the primitive lands in Phase 0): `Merge(loserID, winnerID)` rewrites the loser file to a tombstone stub (`status: tombstone`, `redirect_to`), moves its aliases to the winner in both frontmatter and index, appends a `merged from` line to the winner. One commit. Incoming links are NOT rewritten (lazy, by later page rewrites).

## Consolidation v1 (daemon phase)

Order in `daemon.Run`: after `phaseInbox` (situations must be fresh), before `phaseNextStep`. Skipped entirely when `memory.enabled` is false.

Each run, bounded by `memory.max_chunk_messages` (default 2000) and `memory.max_runtime` guard:

1. **Reconcile** vault ↔ index; commit owner edits if any (MEM-03).
2. **Seed new entities** (mechanical, no AI): people with ≥`memory.seed_min_messages` (default 20) messages in the last 30 days lacking a node; channels with text lacking a node; Jira projects. Natural keys as aliases; `refs.people_card` linked when one exists.
3. **Ingest situations**: for each situation not yet ingested (tracked via alias `situation:<id>` on the episode node — no new column on `situations`): open → create/update a `tier: short` episode; done/stale/converted → finalize (`status: closed`, `tier: long`, outcome from `resolved_reason`/conversion). Chronology and inbox-item message refs copied as provenance (they are detector-written and resolve 100% per the audit — still re-validated on write, MEM-01).
4. **Extract episodes from raw text** (AI, cheap tier): messages with non-empty `text`, `is_bot=0`, ts > watermark, grouped per channel into windows; skip channels already fully covered by a situation episode for that window. Prompt `memory.extract_episodes` returns strict JSON: `[{title, story, outcome|null, participants:[user_id], refs:[{channel_id, ts}], entity_hints:[alias]}]`. Every `refs[]` entry is checked against `messages` — **unresolvable refs are dropped; an episode whose refs all fail is discarded and counted** (`refs_rejected` in the step log). `entity_hints` resolve via aliases to link episodes to entity pages (append to the entity's `## Links` if absent).
5. **Advance watermark** to the last message of the last *fully processed* window — never past an unprocessed one (same freeze discipline as INBOX-09).
6. One git commit per sub-step batch; `pipeline_runs` row per run, `pipeline_steps` per sub-step with token accounting.

Failure semantics: an AI failure in step 4 leaves the watermark at the last committed window and never touches steps 1–3 results (they are already committed). Per-window extraction failures skip that window's advance, log, continue to the next channel.

### Prompt

`memory.extract_episodes` — registered per the `add-ai-prompt` skill, must work on both claude and codex providers, **cheap tier** (haiku / mini class). Input: channel context line (name, running_summary one-liner if any), the window's messages as `[ts] author: text` lines (real ts — the model copies, never invents; the validator enforces). Output cap ~5 episodes per window; instructed to return `[]` for routine chatter — most windows are not episodes.

## MCP Tools

In `internal/mcp/memory.go`, registered alongside `list_people` etc., read-only, backed by the index + vault files:

- **`memory_map`** () → contents of `map.md` + counts by type/tier. The v1 `map.md` is rendered mechanically at the end of each consolidation run: entities grouped by kind with one-line `## What` excerpts, recent open episodes. (LLM-written map is Phase 3.)
- **`memory_open`** (ref: id|alias) → resolved node: canonical id, type, tier, status, markdown body, outgoing links, aliases. Increments `memory_node_stats`. Tombstone chase is transparent; response carries the canonical id so callers self-heal.
- **`memory_recall`** (query, limit=10) → FTS5 hits: id, title, type, snippet. Alias exact-match hits rank first (free synonym resolution). Increments stats for opened… no — recall does **not** increment stats; only `memory_open` does (recall is browsing, open is use).

## CLI

`cmd/memory.go`: `watchtower memory status` (node counts, watermark, debt, last run), `memory reindex` (drop + rebuild index from vault), `memory open <ref>`, `memory recall <query>`, `memory consolidate --once` (manual run, respects the same caps), `memory seed --dry-run`.

## Config

```yaml
memory:
  enabled: false            # off by default until the feature settles
  max_chunk_messages: 2000
  seed_min_messages: 20
  max_episodes_per_window: 5
```

Vault path is not configurable in v1 (always `WorkspaceDir()/memory`). Model routing via the standard tier mechanism, not per-feature config.

## Behavioral Contracts (proposed → docs/inventory/memory.md)

- **MEM-01 (validated provenance):** no message reference is ever written to the vault unless it resolves against the local `messages` table at write time. Refs that fail are dropped and counted, never "fixed up".
- **MEM-02 (rebuildable index):** dropping all memory_* tables and running reindex reproduces an index equivalent to incremental maintenance (guard test compares full dumps).
- **MEM-03 (owner edits are sacred):** manual vault changes are committed as a separate `owner-edit` commit before any machine write in the same run; a machine commit never contains owner working-tree changes.
- **MEM-04 (chunk atomicity):** the watermark advances only in the same run step that committed the corresponding vault changes; a crash between commit and watermark re-processes the chunk (idempotent by node-ID upsert) rather than skipping it.
- **MEM-05 (INBOX isolation):** consolidation reads situations/messages but writes nothing to inbox tables and never moves `inbox_last_processed_ts`.

## Testing

Go (all phases testable without an LLM except the extractor's prompt-shape test):
- vault: init, node round-trip (frontmatter+body), commit messages, owner-edit detection (dirty tree → separate commit).
- resolver: alias case-insensitivity, redirect chains, cycle guard, tombstone chase.
- index: reconcile after file edit / delete / rename; reindex-from-scratch equivalence (MEM-02 guard).
- merge primitive: aliases move, tombstone written, one commit.
- ingest: situation → episode mapping incl. finalize transitions; provenance re-validation.
- extract: fake AI client returning fixture JSON — ts validation drops bad refs (MEM-01 guard: fixture with hallucinated ts must not reach the vault); watermark freeze on failure (MEM-04).
- daemon: phase ordering, disabled-flag skip, pipeline_runs accounting incl. separate cache columns.
- MCP: the three tools against a seeded temp vault; stats increment on open only.

Manual E2E (pre-merge): enable on a dev workspace → seed → two consolidate runs → open vault in Obsidian (links, aliases work) → `memory reindex` → `memory_recall` via MCP inspector.

## Estimated Size

- Phase 0 (vault, node, resolver, index, merge, CLI reindex/status): ~1.5–2K LOC Go + migration.
- Phase 1 (seed, map render, MCP tools, CLI open/recall): ~800 LOC.
- Phase 2 (ingest, extractor + prompt, daemon phase, accounting): ~1–1.5K LOC.

## Follow-ups (own specs later)

- **Phase 3 — semantic tier:** strong-tier entity-page rewrites from accumulated episode deltas (staggered, hundreds of pages); beliefs (confidence, evidence, shaken, asymmetric hysteresis); LLM-written root map; eviction into rollups; retention scoring.
- **Phase 4 — surfaces:** working-memory injection + agentic memory tools in Discuss (owner-rank writes from chat); revision lines in briefings; dispute situations via the `watchtower` detector; reflection over git log.
- Unblockers owned elsewhere: Jira sync repair; digest `key_messages` fix-or-drop; AI-chat token accounting.

## Open Questions

- ULID vs short random suffix for IDs (ULID preferred: sortable, collision-free; length is ugly in links but labels hide it).
- Whether seed should also create entity stubs for the 2 Jira projects while the sync is dead (lean: yes, cheap, aliases ready for when it revives).
- `map.md` size discipline once entities reach hundreds (likely: kind sections capped with "and N more — memory_recall").
