# Knowledge Search — design

**Date:** 2026-09-26
**Status:** Approved for implementation (owner, 2026-09-26)
**Inspiration:** Onyx (`onyx-dot-app/onyx`, commit e0de283) — its document model, two-gate change detection and multi-query rank fusion, minus everything that exists only for many users (ACLs, OpenSearch, Celery, KG, per-chunk contextual RAG).

## 1. Problem

Watchtower keeps every Slack message, mail, Jira issue, calendar event and transcript locally, and derives digests, decisions and recaps from them. The proactive pipelines (Catch-Up, briefing, day plan) assemble their context by time window and entity, and that works. What does not work is the owner **asking a question in chat** — "what did we agree with X about Y", "where did we discuss Z", "what happened with PROJ-123":

- Full-text search exists on only three tables (`messages_fts`, `transcripts_fts`, `memory_fts`). Gmail, IMAP, Jira, calendar, digests, decisions and recaps have none (ideas use `LIKE`).
- `SearchMessages` and `SearchTranscripts` order matches by **date**, not relevance — `bm25()` is used nowhere.
- The Slack unit of search is one message, so a hit is a context-free line ("ok, let's do that").
- The query is an AND of quoted terms: no word forms, no synonyms, no RU↔EN. `porter` stems English only, and `ё` is not folded to `е` (verified: `договорен*` does not match «Договорённость»).
- The chat is told to "start with list_messages" and finds things by trial and error.

## 2. Goal and success criterion

One mechanical, local, derived search index over raw and derived knowledge, exposed as a chat/MCP tool, so that a topical question in chat reaches the right thread/mail/ticket/meeting on the first tool call, with a source-native anchor the chat can link.

**Success:** on the owner's real database, `watchtower kb search` returns the relevant document in the top 5 for a hand-picked set of topical questions (manual smoke, reported in the PR — real data never enters the repo), and the chat prompts route topical questions through `search_knowledge` first.

## 3. Decisions (owner, 2026-09-26)

1. **First consumer: the chat.** Pipelines (meeting prep, `find_experts`, `get_task_context`) may adopt it later; v1 does not change them.
2. **No vectors in v1.** FTS5 + bm25 + multi-query weighted RRF + recency. The schema leaves room for vectors (a later slice, after measuring quality); no new dependency now. Note for that slice: `modernc.org/sqlite` cannot load extensions (no sqlite-vec) — brute-force cosine in Go over BLOBs is the fallback, and claude/codex CLIs have no embeddings API.
3. **Sources: raw + our derived, not memory.** Memory keeps its own `memory_fts` and `memory_recall`.
4. **Approach A:** a unified derived index (`kb_*` tables) filled by a mechanical daemon phase — not per-table FTS federation, not the memory vault.
5. **Query expansion is done by the chat model** (it passes several queries), not by extra light-tier calls inside the tool. **No LLM relevance filter** — the chat model reads compact snippets and opens what it needs.

## 4. Architecture

```
source tables ──(adapters: Changed / Keys / Build)──► Indexer ──► kb_documents
 messages, gmail_messages, imap_messages,                          kb_chunks ──(triggers)──► kb_fts
 jira_issues+jira_comments, calendar_events,                       kb_sources (cursors)
 meeting_transcripts, meeting_recaps,
 digests/digest_topics, stream_digests, ideas+idea_mentions

 search_knowledge / get_knowledge_document (MCP read tools) ──► kb.Search ──► kb_fts + kb_documents
 watchtower kb status | reindex | search (CLI)
 daemon phaseKnowledgeIndex (after the syncs, before the pipelines)
```

New package `internal/kb/` (indexer, source adapters, chunker, normalizer, query builder, search/fusion). All kb SQL lives in `internal/kb` (feature-package raw SQL, the `internal/inbox` detector precedent). Tools in `internal/tools/knowledge.go`. CLI in `cmd/kb.go`. Go-only except for prompt text in the Swift chat view models (§9).

## 5. Data model (migration `00072_knowledge_index.sql`)

```sql
CREATE TABLE kb_documents (
    id            TEXT PRIMARY KEY,          -- the ref, e.g. 'slack:thread:1:C1:1700000000.000100'
    source        TEXT NOT NULL,             -- slack|gmail|imap|jira|calendar|transcript|recap|digest|stream_digest|idea
    title         TEXT NOT NULL DEFAULT '',
    doc_time      TEXT NOT NULL DEFAULT '',  -- ISO8601 UTC, latest activity in the document
    doc_time_unix REAL NOT NULL DEFAULT 0,
    link          TEXT NOT NULL DEFAULT '',  -- permalink/html_link/browse URL when the source has one
    anchor_json   TEXT NOT NULL DEFAULT '{}',-- source-native locator (channel_id+ts, thread_id, issue key, ...)
    meta          TEXT NOT NULL DEFAULT '',  -- searchable names/labels line (people, channel, status, labels)
    content_hash  TEXT NOT NULL DEFAULT '',  -- sha256 of rendered title+meta+chunks
    chunk_count   INTEGER NOT NULL DEFAULT 0,
    indexed_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_kb_documents_source_time ON kb_documents(source, doc_time_unix);

CREATE TABLE kb_chunks (
    id      INTEGER PRIMARY KEY,             -- FTS content_rowid
    doc_id  TEXT NOT NULL REFERENCES kb_documents(id) ON DELETE CASCADE,
    idx     INTEGER NOT NULL,
    title   TEXT NOT NULL DEFAULT '',        -- document title, repeated for bm25 column weighting
    body    TEXT NOT NULL,
    meta    TEXT NOT NULL DEFAULT '',        -- document meta, repeated
    anchor  TEXT NOT NULL DEFAULT '',        -- locator of the chunk's first section (e.g. message ts, start_sec)
    UNIQUE(doc_id, idx)
);

CREATE VIRTUAL TABLE kb_fts USING fts5(
    title, body, meta,
    content='kb_chunks', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
-- kb_chunks_ai / kb_chunks_ad / kb_chunks_au triggers keep kb_fts in sync (external-content 'delete' rows)

CREATE TABLE kb_sources (
    source             TEXT PRIMARY KEY,
    cursor             TEXT NOT NULL DEFAULT '',  -- per-source change watermark (rowid or ISO time)
    last_reconciled_at TEXT NOT NULL DEFAULT '',
    updated_at         TEXT NOT NULL DEFAULT ''
);
```

Mirrored into `schema.sql`, `TestAllTablesExist`, and the schema golden. The indexer deletes a document's chunks explicitly before its row (no reliance on cascade-fired triggers).

## 6. Document units and rendering

A document is rendered as **title**, **meta** (one line of names/labels) and ordered **sections**; sections are packed into chunks.

| Source | Unit (ref) | Title | Sections | Link / anchor |
|---|---|---|---|---|
| Slack thread | `slack:thread:<channel_id>:<thread_ts>` — all rows with that `thread_ts` (the root has `thread_ts = ts`) | `#channel — ` first line of root (≤80 chars) | one per message: `Name: text` | root `permalink`; anchor `{channel_id, ts}` per chunk = first message ts |
| Slack channel-day | `slack:day:<channel_id>:<YYYY-MM-DD>` (UTC) — rows with empty/NULL `thread_ts` | `#channel · date` (DM: `DM with Name · date`) | one per message | first message permalink; per-chunk anchor ts |
| Gmail thread | `gmail:<account_id>:<thread_id>` | first subject | `From Name <email> · date` + body, per message by `internal_date` | latest message `permalink`; `{account_id, thread_id}` |
| IMAP message | `imap:<account_id>:<uidvalidity>:<uid>` (no thread column) | subject | header + body | `permalink` |
| Jira issue | `jira:<account_id>:<KEY>` | `KEY summary` | description, then `Author: comment` by `created_at` | `jira_accounts.site_url + /browse/KEY`; `{key}` |
| Calendar event | `calendar:<event_id>` | event title | header (`When/Where/Organizer/Attendees`) + description | `html_link` |
| Transcript | `transcript:<id>` | title + date | non-deleted `segments_json` utterances `[speaker] text` (anchor `start_sec`), else `transcript_text` lines | none; `{transcript_id}` |
| Meeting recap | `recap:<id>` | event title or `Meeting recap` | string leaves of `recap_json`, in order | `{recap_id, event_id}` |
| Digest topic | `digest:<topic_id>` | topic title | summary, decisions, action items | `{digest_id, channel_id}`; meta carries channel name + digest type |
| Stream digest topic | `stream_digest:<id>:<idx>` | topic title | topic summary fields | `{stream_digest_id, source}` |
| Idea/decision | `idea:<id>` | title | essence, then mention quotes | `{idea_id}`; meta carries kind + status |

Rules:
- **Normalization** (index and query alike): `ё→е`, `Ё→Е`; Slack markup resolved — `<@U…>` → `@Name` (account from the channel prefix, `UserNameByRawID`-style lookup), `<#C…|name>` → `#name`, `<url|label>` → `label (url)`.
- Skipped: `is_deleted` Slack rows, join/leave-style subtypes, deleted Jira issues. A document with no sections is deleted from the index.
- **Chunking:** sections are packed into chunks of up to `chunkChars = 2000` characters; a longer section is split at the last whitespace before the limit (hard split if none). No overlap (Onyx found none helps). Title and meta go into their own FTS columns, not into the body.
- **Change gate:** `content_hash` equal → no write (Onyx gate 2). Unchanged docs cost a render, not a write.

## 7. Indexer

Each source adapter implements:

```go
type Source interface {
    Name() string
    Changed(ctx context.Context, d *db.DB, cursor string, limit int) (keys []string, next string, err error)
    Keys(ctx context.Context, d *db.DB) ([]string, error)          // every current document key (reconcile)
    Build(ctx context.Context, d *db.DB, key string) (*Doc, error) // nil = document no longer exists
}
```

- **Change cursors:** Slack — `messages.rowid` (monotonic for new rows: upserts use `ON CONFLICT DO UPDATE`, which keeps the rowid), processed in rowid ranges of 20 000 rows, plus a **tail rescan** of rows with `ts_unix` in the last 48 h each cycle (catches edits/deletes that upsert in place). Gmail/IMAP — `updated_at`. Jira — `synced_at` of issues and comments (union of keys). Calendar — `synced_at`. Transcripts, recaps, ideas — `updated_at` (ideas also `idea_mentions.created_at`). Digests/stream digests — `created_at` (a re-upserted digest bumps it).
- **Reconcile (deletions):** once per UTC day per source, `Keys()` is diffed against the source's `kb_documents` ids; stale ids are deleted (Onyx slim-doc pruning).
- **Batches:** documents are written in transactions of ≤500; a source's cursor is persisted only after the batch that completes its range, so an interrupted run resumes without loss.
- **Budget:** in the daemon, one cycle spends at most `cycleBudget = 60s`; small sources run first, Slack last, so everything except Slack is searchable after the first cycle and Slack backfill spreads across cycles. The CLI `kb reindex` is unbounded.
- **Daemon phase** `phaseKnowledgeIndex(ctx)`: after `phaseTranscriptAudioCleanup`, gated `if !d.config.Knowledge.Enabled { return }`, wrapped in `trackedPipelineRun("knowledge-index", …)` with `items = documents written` so it shows in Pipeline Progress. A source error is logged, recorded in the run's error, and never stops other sources.
- **Feature:** registry entry `knowledge-search` ("Knowledge search", `CostNone`, config key `knowledge.enabled`, default **true**). Off = no indexing (FEAT-01); the existing index stays readable and is not deleted (FEAT-02). No fast-forward hook: re-enabling resumes from the stored cursors — catching up is mechanical and free, so it is the desired behaviour, not a backfill of AI work (FEAT-03 concerns AI-cost work).

## 8. Search

`kb.Search(ctx, d, Request) (Result, error)`:

```go
type Request struct {
    Queries []string  // 1–5, from the chat model: key terms, synonyms, RU/EN variants, stems with *
    Sources []string  // optional filter
    From, To time.Time // optional, on doc_time
    Limit   int       // documents, default 10, max 25
}
```

1. **Query building** (`buildMatch`): split each query on whitespace; strip punctuation except inner `-`, `_`, `.` (so `PROJ-123` survives as a quoted phrase); fold `ё`; drop FTS keywords; quote every term; keep a trailing `*` as a prefix operator (`"договор"*`). Two MATCH strings per query: **AND** (all terms) and **OR** (any term).
2. **Retrieve:** per query, the AND form returns the top 50 chunks by `bm25(kb_fts, 4.0, 1.0, 2.0)` (title, body, meta), joined to `kb_documents` for the source/time filters. The OR form runs only when AND returned fewer than 50, as a separate list.
3. **Fuse:** weighted reciprocal rank fusion over all lists, `k = 50`; weight 1.0 for AND lists, 0.5 for OR lists (`score += w / (k + rank)`).
4. **Group** chunks by document: document score = its best chunk's score; keep up to 2 best chunks per document for snippets.
5. **Recency:** multiply by `max(1/(1 + 0.5·age_years), 0.75)` (bounded, applied after fusion — Onyx's rule).
6. **Return** the top `Limit` documents: `ref, source, title, when, link, anchor, snippets[]` (FTS5 `snippet()` around the match, ~40 tokens, `…` elision, no markup), plus `index_note` when any source is still backfilling (e.g. `slack 43% indexed`) or the index was last updated over 24 h ago.

`kb.GetDocument(ctx, d, ref, maxChars)` returns the document's chunks in order, joined, capped (default 12 000 chars) with a `truncated` flag.

## 9. Surfaces

- **MCP read tools** (in `tools.ReadTools()`, so both `watchtower mcp` dev mode and the chat get them; DEV-01 covers them — read-only connection, added to `TestToolsList`, `TestAllToolsAreReadOnly` (as a `search_` read verb) and `TestNoToolMutatesDatabase`):
  - `search_knowledge{queries[], sources?, from?, to?, limit?}`.
  - `get_knowledge_document{ref, max_chars?}`.
- **Chat prompts** — Go `internal/ai/prompt.go` and the five Swift prompt copies (`ChatViewModel`, `TargetChatViewModel`, `IdeaChatViewModel`, `MeetingChatViewModel`, `TrackChatView`) gain the tool line; the tool-mode prompts (Go, `ChatViewModel`, `TargetChatViewModel`) change their workflow line from "start with list_messages" to: *for a topical question, start with `search_knowledge` — pass 2–5 queries: the key terms, synonyms, both Russian and English variants, and word stems with `*` for Russian word forms; then open the best hits with `get_knowledge_document` or the source tools. Use `list_messages` for "latest from person/channel" questions.* `TestBuildSystemPrompt_NamesRegisteredTools` gains both names.
- **CLI** `watchtower kb`:
  - `status [--json]` — per source: documents, chunks, cursor, backfill %, last reconcile.
  - `reindex [--source S]` — drop the source's (or all) documents and cursors, rebuild unbounded.
  - `search <query>... [--source S] [--from --to] [--limit N] [--json]` — the same `kb.Search` as the tool (owner debugging and the success smoke).

## 10. Contracts (`docs/inventory/knowledge-search.md`)

- **KB-01 — derived and rebuildable.** The `kb_*` tables are an index, never a source of truth: nothing reads them to make a decision other than search, the indexer never writes a source table, and a from-scratch `kb reindex` produces the same `kb_documents`/`kb_chunks` content as incremental indexing over the same data. Guard: `TestKB01_IncrementalEqualsRebuild` (index a fixture in two incremental passes with changes/deletions in between, dump; rebuild from scratch, dump; equal) and a source-tables-byte-identical check.
- **KB-02 — mechanical.** Indexing and search make no model calls. Guard: `TestKB02_NoGeneratorImports` — a `go/parser` scan that `internal/kb` imports none of the generator packages (`internal/digest`, `internal/ai`, `internal/codex`, `internal/ollama`, `internal/providers`).
- **KB-03 — every hit is resolvable.** Every search result carries a `ref` that `get_knowledge_document` opens and a non-empty source-native `anchor`. Guard: `TestKB03_EveryHitOpensAndAnchors` over a fixture covering every source.

Read-only-ness is DEV-01's, not restated. Module row added to `docs/inventory/README.md`.

## 11. Testing

- `internal/kb`: per-adapter render tests (thread grouping incl. root, channel-day split, DM title, mention resolution, Jira comment order, Gmail thread order, transcript segments with deleted ones skipped, recap JSON flattening); chunker (packing, split of an oversized section, anchors); normalizer (`ё`, markup); `buildMatch` (quoting, prefix `*`, `PROJ-123`, FTS keywords, empty query); fusion (RRF math, OR-list weight, grouping, recency floor); indexer (cursor resume after a mid-run stop, tail rescan picks up an in-place edit, hash gate skips unchanged, reconcile deletes, budget stop); morphology integration (`договор*` hits «договорились», `договорен*` hits «договорённость»).
- Degenerate inputs: empty source tables, all-deleted thread, empty query list, queries of only punctuation, `limit` 0/over max.
- Contracts KB-01..03 guards; DEV-01 guard lists extended; tools list tests; prompt names test; feature registry test.
- Manual: `kb reindex` timing and DB growth on the owner's database, and the success smoke (§2), both reported in the PR.

## 12. Out of scope (v1)

Vectors/embeddings; LLM query expansion or relevance filtering inside the tool; memory in the index; switching `list_messages`/`find_experts`/meeting prep to the new index; Desktop UI beyond prompt text (the feature toggle appears in Settings → Features automatically via the CLI); per-section link offsets (a chunk anchors at its first section); cross-account dedup.
