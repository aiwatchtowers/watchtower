# Ideas & Decisions Registry — Design

**Date:** 2026-08-07
**Status:** approved (owner walkthrough 2026-08-07, section-by-section)
**Owner decisions baked in:** auto-capture is the primary scenario ("nothing gets lost"); all four sources (Slack, meeting transcripts, Jira incl. comments, Gmail); ideas AND decisions from day one, notes as a third kind; full lifecycle; own sidebar tab with badge; auto-link + resurfacing; batch mining a few times a day over properly prepared data (source-leveling: every stream gets a semantic pre-digest).

## 1. Problem

Ideas surface everywhere — meetings, Slack threads, Jira comments, email — and die there. Some are good, some are noise, some are simply "not now". There is no registry that catches them, tracks repeat mentions, lets the owner triage them (approve / reject / not now), matures them over time, and converts the good ones into Targets. Decisions have the same shape: they get made in the same streams and are equally lost. The secretary should be able to answer "what ideas do we have about X?" at any time.

## 2. Goals

- **Nothing gets lost:** the system mines ideas and decisions out of all connected streams on its own; the owner only triages.
- One registry for three kinds: `idea`, `decision`, `note` (notes = owner-written quick captures, no triage flow).
- Full idea lifecycle: proposed → approved/rejected; then active ↔ not-now → converted (to Target) / dropped. Decision-specific: superseded / reversed.
- Re-linking: a repeat mention of a known item attaches to it (no duplicate triage); a repeat mention of a rejected/dropped/not-now item resurfaces it ("they brought it up again").
- Owner can create ideas/notes/decisions by hand; 👍/👎 with optional comment trains the miner.
- Per-item Discuss chat with full item context; secretary-wide search via MCP tools.
- Batch mining a few times a day (no real-time requirement), over pre-digested data so the expensive pass sees a small, dense input.

## 3. Non-goals (v1)

- No decisions→track/target conversion (ideas convert to Targets; decisions just live in the registry).
- No automatic merge of duplicates — the miner emits `similar_to` hints; merging is an owner action.
- No memory-vault integration (neither staging idea chats into memory nor mining from memory episodes). Follow-up slice once memory is on by default.
- No idea sharing/publishing; single-owner like the rest of the app.
- No backfill over historical data: mining starts from the floors set at migration time (current max ids). **As built:** migration 00050 seeds the three `workspace` floors with `MAX(id)` of `digest_topics` / `stream_digests` / `meeting_transcripts`. The two per-account stage-1 floors are seeded differently — they self-initialize on their first run — because an account connected *after* the migration has no migration of its own to seed it. A later `ideas mine --since` backfill is a possible follow-up.

## 4. Architecture overview

Two-stage pipeline, deliberately asymmetric in cost:

1. **Stage 1 — substrate preparation (cheap, rides existing reads).** Every stream gets a semantic pre-digest that includes idea/decision candidates:
   - Slack: the existing per-channel digest prompt (`digest.channel`) additionally extracts `ideas` per topic (next to the existing `decisions`).
   - Meetings: the existing recap prompt (`meeting.recap`) additionally extracts `ideas` and `decisions` arrays.
   - Gmail: a **new** light-tier MAP pass produces per-account email digests over new threads.
   - Jira: a **new** light-tier MAP pass produces per-project activity digests over recently updated issues, comments included (new bounded comment sync).
2. **Stage 2 — the consolidator (small, strong-tier, a few times a day).** A throttled daemon phase reads only *new* stage-1 output (mechanical per-source floors), plus a slice of the current registry and the owner-preference block, and emits ops: `new_idea` / `new_decision` / `attach_mention` / `similar_to`. Go validates every provenance ref against the stage-1 input (invented refs are dropped and counted, never written — the MEM-13 pattern) and applies the ops.

The owner triages in a dedicated Desktop tab; feedback loops back into the consolidator prompt.

## 5. Data model (migration 00050)

### 5.1 `ideas`

```sql
CREATE TABLE ideas (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    kind            TEXT NOT NULL CHECK(kind IN ('idea','decision','note')),
    title           TEXT NOT NULL,
    essence         TEXT NOT NULL DEFAULT '',   -- 1-2 sentence gist (miner- or owner-written)
    status          TEXT NOT NULL DEFAULT 'proposed'
                    CHECK(status IN ('proposed','active','rejected','not_now',
                                     'converted','dropped','merged','superseded','reversed')),
    source          TEXT NOT NULL DEFAULT 'mined' CHECK(source IN ('mined','owner')),
    snooze_until    TEXT NOT NULL DEFAULT '',   -- optional, for not_now
    needs_review    INTEGER NOT NULL DEFAULT 0, -- resurfacing flag
    review_reason   TEXT NOT NULL DEFAULT '',   -- "brought up again in #channel"
    similar_to_id   INTEGER,                    -- miner hint on proposed items
    merged_into_id  INTEGER,                    -- set when status='merged'
    superseded_by_id INTEGER,                   -- decisions: set when status='superseded'
    converted_target_id INTEGER,                -- set when status='converted'
    owner_rating    INTEGER NOT NULL DEFAULT 0, -- -1 / 0 / +1
    rating_comment  TEXT NOT NULL DEFAULT '',
    last_mention_at TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
```

Status semantics per kind (enforced in code, one CHECK for all):
- `idea` (mined): proposed → active | rejected; active ↔ not_now; active/not_now → converted | dropped; any → merged (owner merge).
- `idea` (owner-created): born `active`, same transitions afterwards.
- `decision`: proposed → active | rejected (mined) or born active (owner); active → superseded (with `superseded_by_id`) | reversed.
- `note`: born `active`; only dropped/merged apply. Notes never enter triage.

`owner_rating` is a learning signal, not a status: the consolidator prompt receives a preferences block built from recent rejected/disliked and approved/liked examples (the `buildUserPreferencesBlock` precedent).

### 5.2 `idea_mentions`

The provenance trail (the `situation_signals` analogue). One row per sighting; the item's chronology is its mentions ordered by `said_at`.

```sql
CREATE TABLE idea_mentions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner')),
    ref         TEXT NOT NULL DEFAULT '',  -- slack: "<channel_id>|<ts>"; meeting: transcript id;
                                           -- gmail: "<account_id>:<thread_id>"; jira: issue key
    quote       TEXT NOT NULL DEFAULT '',  -- verbatim-ish quote from the digest/recap
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_idea_mentions_idea ON idea_mentions(idea_id);
```

### 5.3 `stream_digests` (stage-1 output for Gmail and Jira)

Slack digests stay in `digests`/`digest_topics` (Desktop reads them; not touched structurally). Email and Jira pre-digests get one shared table:

```sql
CREATE TABLE stream_digests (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK(source IN ('gmail','jira')),
    account_id   INTEGER NOT NULL,           -- google_accounts.id / jira_accounts.id
    scope        TEXT NOT NULL DEFAULT '',   -- reserved; always '' as built (see §6.4)
    period_from  TEXT NOT NULL,
    period_to    TEXT NOT NULL,
    topics_json  TEXT NOT NULL DEFAULT '[]', -- [{title, summary, ideas[], decisions[], refs[]}]
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
```

### 5.4 `jira_comments` (new bounded sync)

```sql
CREATE TABLE jira_comments (
    account_id  INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key   TEXT NOT NULL,
    id          TEXT NOT NULL,               -- Jira comment id
    author      TEXT NOT NULL DEFAULT '',
    body_text   TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT '',
    updated_at  TEXT NOT NULL DEFAULT '',
    synced_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (account_id, id)
);
CREATE INDEX idx_jira_comments_issue ON jira_comments(account_id, issue_key);
```

Sync is bounded: during each Jira sync pass, comments are fetched only for issues whose `updated_at` moved in that pass (one extra API call per touched issue), upserted by comment id. No historical backfill.

### 5.5 Column additions & enum expansion

- `digest_topics` + `ideas TEXT NOT NULL DEFAULT '[]'` (JSON array of `{text, message_ts, author}` like `decisions`).
- Meeting recap JSON (`meeting_recaps` row / `meeting_transcripts.summary_json`) gains optional `ideas`/`decisions` arrays — JSON-shape change, no schema change.
- `targets.source_type` CHECK gains `'idea'` — table-recreation dance (00002/00003 precedent).
- `workspace` gains consolidator floors: `ideas_digest_floor INTEGER`, `ideas_stream_digest_floor INTEGER`, `ideas_transcript_floor INTEGER` (last consumed `digest_topics.id` / `stream_digests.id` / `meeting_transcripts.id`).
- Stage-1 source floors: `google_accounts.ideas_email_floor TEXT` (internal-date watermark) and `jira_accounts.ideas_jira_floor TEXT` (ISO updated-at watermark), one per account — the per-account watermark precedent from the multi-account work.
- Chat: `chat_conversations.context_type='idea'` (Swift-side; the allowed-set lives in code, no schema change; memory's `chatContextTypes` is NOT extended — v1 non-goal).

All tables mirrored into `internal/db/schema.sql`, added to `TestAllTablesExist`, golden snapshot regenerated.

## 6. Stage 1 — substrate preparation

### 6.1 Slack (prompt change only)

`digest.channel` (and the batch variant) is extended: each topic may carry `ideas: [{text, message_ts, author}]` next to `decisions`. Prompt version bumped; parser tolerates the field's absence (old digests stay valid). Persisted to `digest_topics.ideas`.

### 6.2 Meetings (prompt change only)

`meeting.recap` is extended with optional `ideas` and `decisions` arrays (`{text, speaker}`). Both recap paths carry them (event-linked `meeting_recaps` and ad-hoc `summary_json`) — the existing collision guard is untouched; the arrays are part of the recap JSON either way.

### 6.3 Gmail — new `ideas.digest_email` pass (light tier)

Runs inside the ideas daemon phase, before the consolidator. Per enabled Gmail account: collect threads with new messages since the account's floor (`google_accounts.ideas_email_floor`, new column — internal-date watermark, the Gmail-sync precedent), chunked; one light-tier call per chunk produces `topics_json` (title, summary, ideas[], decisions[], refs = `<account_id>:<thread_id>`). Rows land in `stream_digests(source='gmail')`. Floor advances only after a successful write (INBOX-09 spirit). Skipped silently when Gmail is not connected.

### 6.4 Jira — new `ideas.digest_jira` pass (light tier)

Per enabled Jira account, over the issues updated since the account's floor (`jira_accounts.ideas_jira_floor`, a Jira-format timestamp): input = changed issues (summary, description excerpt, status) + their new comments from `jira_comments`. Produces `topics_json` with refs = issue keys. Same floor semantics.

**As built:** one call per *account*, not per project — the issues are grouped under `=== PROJECT <KEY> ===` separators inside a single prompt, and the resulting `stream_digests` row carries `scope = ''` like the Gmail one. Per-project scoping was designed for but not needed at v1 volumes; the `scope` column is left in place, unused, for when it is.

### 6.5 Prompt registry

New prompt ids: `ideas.digest_email`, `ideas.digest_jira`, `ideas.consolidate` (below) — registered in `internal/prompts` with both claude and codex routing, light/light/strong tiers respectively.

## 7. Stage 2 — the consolidator

**Trigger:** daemon phase `phaseIdeas`, after `phaseChannelDigests` (so fresh Slack digests are visible), throttled by `ideas.mine_interval_hours` (default 6; the `phasePeopleCards` throttle precedent). Runs only when at least one floor has new material. Config gate `ideas.enabled` (default **true** — this is a headline feature, not a dark experiment; the expensive part is capped).

**Input assembly (mechanical):**
- New `digest_topics` rows (id > `ideas_digest_floor`) that have non-empty `ideas` or `decisions`, with channel names.
- New `stream_digests` rows (id > `ideas_stream_digest_floor`).
- New `meeting_transcripts` rows (id > `ideas_transcript_floor`) — their recap `ideas`/`decisions` arrays only.
- Registry slice: all items with status in (proposed, active, not_now) plus items touched in the last 60 days — id, kind, title, essence, status.
- Preferences block: recent owner verdicts (approved/liked vs rejected/disliked titles + rating comments).

**Output contract (strong tier, one call per run, capped input — overflow carries to the next run by not advancing the floor past the last included row):**

```json
{"ops": [
  {"op": "new_idea",      "title": "...", "essence": "...", "mentions": [{"source": "slack", "ref": "C123|1723...", "quote": "...", "author": "...", "said_at": "..."}], "similar_to": 42},
  {"op": "new_decision",  "title": "...", "essence": "...", "mentions": [...]},
  {"op": "attach_mention","idea_id": 17, "mention": {...}}
]}
```

**Go-side application (all in one transaction per run):**
- Every mention `ref` must resolve to a ref present in this run's stage-1 input; an invented ref drops the mention (and the whole op if it loses all mentions), incrementing a `refs_rejected` counter (IDEA-02, the MEM-13 pattern).
- `new_idea`/`new_decision` → `ideas` row `status='proposed'`, `source='mined'`, mentions inserted, `similar_to_id` kept as a hint.
- `attach_mention` to an item in (active, proposed) → mention row + `last_mention_at`.
- `attach_mention` to an item in (not_now, dropped, rejected) → mention row + `needs_review=1`, `review_reason` set; **status unchanged** (IDEA-04).
- `attach_mention` to (converted, merged, superseded, reversed) → mention row only (history keeps accruing on terminal items; merged items redirect to `merged_into_id`).
- Floors advance to the max consumed id per source **only when the whole run applied cleanly**; on AI failure or apply error nothing advances and nothing is written (IDEA-01).

## 8. Desktop UI

New sidebar tab **Ideas** (badge = count of `proposed` + `needs_review=1`). Master-detail (Dashboard layout precedent):

- **List (left):** "For review" section on top (proposed + resurfaced), then the registry with kind and status filter chips and a text search field (LIKE over title/essence/mention quotes). Row: kind glyph, title, essence snippet, source glyphs, last-mention date.
- **Detail (right):** essence, status, rating control (👍/👎 + optional comment), action bar driven by kind+status: Approve / Reject (proposed); Not now (with optional date) / Activate; Convert to Target; Merge (picker, pre-filled from `similar_to_id`); Drop; Supersede / Reverse (decisions). Below: mentions chronology (quote bubble, author, deep link — Slack permalink, transcript, Gmail thread, Jira issue), then a collapsed Discuss chat.
- **Create (+):** manual idea / note / decision — title + free text (goes to `essence`), born `active`, `source='owner'`, plus an `owner` mention row carrying the text.
- Chat: `IdeaChatViewModel` — the deliberate house-pattern copy of the Situation/Target/Meeting chat VMs, `context_type='idea'`, `context_id=idea id`. System prompt inlines the item card + mentions and points at the MCP tools.
- Swift writes verdicts/ratings/merge directly via GRDB (`IdeaQueries`) — the feedback dual-path precedent. Approve = `status='active'`; Convert creates the Target row via the existing CLI/queries path used by situations conversion.

## 9. Secretary integration & CLI

- MCP read tools (`internal/mcp`): `list_ideas` (filter by kind/status/query) and `get_idea` (card + mentions) — any secretary chat can answer "what ideas do we have about X".
- CLI: `watchtower ideas mine` (force one consolidator run, envelope with counts + `refs_rejected`), `watchtower ideas list [--kind --status]`.

## 10. Behavioral contracts (`docs/inventory/ideas.md`, new)

- **IDEA-01 (floor honesty):** a consolidator failure — AI error, parse error, apply error — advances no floor and writes nothing; stage-1 material is never consumed without being applied. When the input cap truncates a run, floors advance only past the rows actually included.
- **IDEA-02 (no invented provenance):** every mention ref is validated against the run's stage-1 input; invented refs are dropped and counted, never persisted.
- **IDEA-03 (links, not deletes):** convert and merge keep the original row (`converted_target_id` / `merged_into_id`); no cascade deletion of mentions or chat.
- **IDEA-04 (resurfacing respects the verdict):** a repeat mention of a rejected/dropped/not-now item sets `needs_review` + reason but never changes `status`; only the owner moves an item out of a verdict status.

## 11. Testing

- **Go:** consolidator apply unit tests (ref validation, op application per status, transaction atomicity); floor-semantics guard tests for IDEA-01 (AI error, malformed JSON, mid-apply failure, cap truncation) and IDEA-04 (resurfacing); prompt-parse tolerance tests (digest topics with/without `ideas`; recap with/without arrays); jira comment sync bounded-fetch test; migration golden + `TestAllTablesExist`.
- **Swift:** `IdeaQueries` round-trips, list projection never selects mention bodies (perf-guard precedent), VM tests for triage actions and badge count. **As built,** the per-kind status machine is enforced at the *view* layer — `IdeaDetailPane.statusActionsRow` only renders the actions legal for the current kind+status — rather than by a rejecting write in `IdeaQueries`. So the guards are reachability tests (every status a resurfacing can flag offers an action that clears `needs_review`), not rejected-transition tests.
- **Degenerate inputs** (per house feedback): consolidator run with zero new material is a clean no-op; stage-1 pass with an empty chunk writes nothing and still advances its own floor only on success.

## 12. Follow-up slices (explicitly out of v1)

1. Memory episodes as an extra mention source once memory is on by default.
2. Idea chats staged into memory (`chatContextTypes` + provenance resolver).
3. Historical backfill (`ideas mine --since`).
4. Decisions → dashboard cross-surfacing (dedupe with the existing `decision_made` situations from memory disputes).
5. Digest-screen rendering of `digest_topics.ideas` (Desktop digest UI currently ignores the new column).
