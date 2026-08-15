# Slack-id JSON backfill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Migrate the Slack ids frozen inside JSON blobs to the namespaced form migration 00048 gave every scalar id column, so the six read sites that silently stopped matching start working again — and pin each of them with a test that would fail if either side of the comparison drifts.

**Architecture:** One goose SQL migration (00054) rewriting six JSON columns in place, using SQLite's JSON1 functions (`json_each` / `json_group_array` / `json_set`, already used in production queries through the modernc driver). No Go production code changes. Tests: one migration test file following the `internal/db/jira_accounts_migration_test.go` pattern (`goose.UpTo` to N-1, seed legacy shape, `UpTo` to N, assert), plus per-call-site pinning tests.

**Tech Stack:** Go 1.25, goose v3, modernc.org/sqlite.

## Background (verified, not assumed)

Migration 00048 (Slack multi-account) rewrote **only scalar TEXT id columns** to `"<accountID>:<rawID>"`. JSON-array columns were deliberately left as frozen bare text. On the owner's live database that means 906 of 961 tracks carry bare `channel_ids`, 958 carry bare `participants`, and the profile lists are bare — so these comparisons never match again:

| # | Read site | Blob (bare) | Compared against (namespaced) | Consequence |
|---|-----------|-------------|-------------------------------|-------------|
| 1 | `internal/tracks/pipeline.go:1431` `existingTrackChannels[channelID]` | `tracks.channel_ids` | live `channels`/`messages.channel_id` | channel loses the heaviest (+3/9) relevance signal; at score 0 `filterEntriesByRelevance` drops it and the existing track stops receiving updates |
| 2 | `internal/tracks/pipeline.go:1434` `starredChannels[channelID]` | `user_profile.starred_channels` | same | starred channel loses its +2 boost |
| 3 | `internal/guide/pipeline.go:911,921` `relationshipContext` | `user_profile.reports`/`peers` | `stats.UserID` | people card never says "direct report"/"peer" |
| 4 | `internal/tracks/pipeline.go:1450` `relatedUsers` | `user_profile.reports`/`peers` | fresh digest-topic JSON (namespaced) | report/peer relevance signal (+1) never fires |
| 5 | `internal/meeting/pipeline.go:392` `gatherSharedContext` | `tracks.participants` | calendar-resolved `users.id` | attendee's shared tracks never render in meeting prep |
| 6 | `internal/db/channel_stats.go:141` `LEFT JOIN track_channels tc ON tc.channel_id = c.id` | `json_each(tracks.channel_ids)` | `channels.id` | the tracks-per-channel stat reads 0 |

`user_profile.manager` is **not** in scope: 00048 rewrites it (line 81) like any scalar column, and the only writer stores a namespaced id.

Not fixable by this migration (documented, out of scope): the memory vault's markdown files, and AI-generated historical text that happens to embed ids.

## Global Constraints

- Everything committed (code, comments, commit messages) is in English.
- Read `.claude/skills/add-migration/SKILL.md` before writing the migration — it encodes the load-bearing steps (numbering, `schema.sql` mirror, golden snapshot, `TestAllTablesExist`).
- This migration changes **no schema** — no new table, column, index, or CHECK. So `internal/db/schema.sql` and the golden snapshot must come out **unchanged**; if `go test ./internal/db/ -run TestSchemaGolden` reports a diff, something is wrong — do not `-update` it away.
- Raw Slack ids never start with a digit and never contain `:`, so `NOT GLOB '[0-9]*:*'` is a safe "not yet namespaced" test. Prefix is `'1:'`, matching 00048's unconditional account-1 rewrite.
- Verify from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/slack-id-json-backfill`:
  - `go build ./... > /tmp/gb.log 2>&1; echo "exit=$?"` — never pipe verification output through `tail`/`head`; redirect and check the code.
  - Package tests only while iterating: `go test ./internal/db/ > /tmp/gt.log 2>&1; echo "exit=$?"`.
- Commit per task; verify `git branch --show-current` prints `fix/slack-id-json-backfill` before each commit. End messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Migration 00054 + migration tests

**Files:**
- Create: `internal/db/migrations/00054_namespace_json_slack_ids.sql`
- Create: `internal/db/json_ids_migration_test.go`

**Interfaces:**
- Produces: migration version `54`. Task 2's pinning tests assume post-migration data is namespaced on both sides.

- [ ] **Step 1: Write the migration.** Six columns, two shapes. `tracks.channel_ids`, `user_profile.reports`, `user_profile.peers`, `user_profile.starred_channels`, `user_profile.starred_people` are flat arrays of id strings; `tracks.participants` is an array of **objects** carrying `$.user_id` (plus `name`/`stance` fields that must survive untouched).

```sql
-- +goose Up
-- Migration 00048 namespaced every scalar Slack id column but deliberately left
-- JSON-embedded ids alone, so any row written before it still carries bare ids
-- that can never match a namespaced column again — silently, since every
-- consumer treats a miss as "no signal" rather than an error.
--
-- Raw Slack ids are alphanumeric and never contain ':', so `NOT GLOB '[0-9]*:*'`
-- identifies the not-yet-namespaced elements; already-namespaced ones are left
-- alone, which also makes this migration safe to re-run.

-- Flat arrays of ids.
UPDATE tracks
SET channel_ids = (
    SELECT json_group_array(
        CASE
            WHEN json_type(je.value) = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
                THEN '1:' || je.value
            ELSE je.value
        END
    )
    FROM json_each(tracks.channel_ids) je
)
WHERE json_valid(channel_ids) AND json_type(channel_ids) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.channel_ids) je
      WHERE json_type(je.value) = 'text' AND je.value != '' AND je.value NOT GLOB '[0-9]*:*'
  );

-- Repeat the identical statement for each of:
--   user_profile.reports, user_profile.peers,
--   user_profile.starred_channels, user_profile.starred_people

-- Array of participant objects: only $.user_id is rewritten, every other field
-- of the object is preserved.
UPDATE tracks
SET participants = (
    SELECT json_group_array(
        CASE
            WHEN json_type(je.value, '$.user_id') = 'text'
             AND json_extract(je.value, '$.user_id') != ''
             AND json_extract(je.value, '$.user_id') NOT GLOB '[0-9]*:*'
                THEN json_set(json(je.value), '$.user_id', '1:' || json_extract(je.value, '$.user_id'))
            ELSE json(je.value)
        END
    )
    FROM json_each(tracks.participants) je
)
WHERE json_valid(participants) AND json_type(participants) = 'array'
  AND EXISTS (
      SELECT 1 FROM json_each(tracks.participants) je
      WHERE json_type(je.value, '$.user_id') = 'text'
        AND json_extract(je.value, '$.user_id') != ''
        AND json_extract(je.value, '$.user_id') NOT GLOB '[0-9]*:*'
  );

-- +goose Down
-- Strip the account-1 prefix back off, mirroring the Up block. Elements that
-- were already namespaced before the Up ran are indistinguishable from ones it
-- created, so Down returns every '1:'-prefixed element to its bare form — the
-- pre-00048 shape.
```

Write the Down block out in full, symmetric to Up (six statements, `WHERE je.value GLOB '1:*'` → `substr(je.value, 3)`; for participants, `json_set(..., substr(json_extract(je.value,'$.user_id'), 3))`).

**Load-bearing detail to verify, not assume:** `json_group_array` must embed `json_set(...)`/`json(...)` results as JSON objects, not as quoted strings. SQLite does this via the JSON subtype; whether the modernc build in this repo preserves it is exactly what Step 3's test proves. If the test shows objects coming back double-encoded, switch that statement to build the array with `json_group_array(json_object(...))` over the extracted fields, or fall back to `json_patch`.

- [ ] **Step 2: Write the failing test** (`internal/db/json_ids_migration_test.go`). Follow `jira_accounts_migration_test.go`: open a raw `*sql.DB` on a temp file, `goose.UpTo(raw, "migrations", 53)`, seed the legacy shape, `goose.UpTo(raw, "migrations", 54)`, assert. Cover:
  - a track whose `channel_ids` is `["C0473A5GC6N","C03GB81BHUJ"]` → both become `1:`-prefixed;
  - a track already namespaced (`["1:C0473A5GC6N"]`) → **byte-identical** after the migration (no double prefix);
  - a mixed array (`["C1","1:C2"]`) → `["1:C1","1:C2"]`;
  - `tracks.participants` seeded as `[{"name":"@A","user_id":"U010F2S53JM","stance":"инициатор"},{"name":"@B","user_id":"1:U0975M7FJR5","stance":"x"}]` → first `user_id` prefixed, second untouched, and **`name`/`stance` preserved exactly** (assert by reading them back with `json_extract`, and assert the element is still a JSON object — `json_type(participants,'$[0]') = 'object'` — which is what catches the double-encoding failure mode);
  - all four `user_profile` list columns;
  - an empty array `[]`, an empty string, and a malformed value (`not json`) → left exactly as they were;
  - re-running the migration is a no-op: after `UpTo(54)`, execute the Up statements a second time (read them from the embedded FS or re-run `goose.DownTo(53)`+`UpTo(54)`) and assert the values are unchanged.
  - a Down/Up cycle test in the `TestMigration00049DownUpCycle` shape: `UpTo(54)` → `DownTo(53)` → values are bare again → `UpTo(54)` → namespaced again.
- [ ] **Step 3: Run the tests, expect failures** (migration not yet applied / assertions unmet): `go test ./internal/db/ -run TestMigration00054 > /tmp/gt.log 2>&1; echo "exit=$?"`.
- [ ] **Step 4: Make them pass.** Iterate on the SQL until green. If `json_group_array` double-encodes, apply the fallback named in Step 1.
- [ ] **Step 5: Full package + schema guard.** `go test ./internal/db/ > /tmp/gt.log 2>&1; echo "exit=$?"` — expect exit 0, and expect `TestSchemaGolden` to pass **without** `-update` (this migration adds no schema).
- [ ] **Step 6: Commit.** `feat(db): migration 00054 — namespace Slack ids frozen in JSON blobs`

---

### Task 2: Pinning tests for the six read sites

**Files:**
- Modify: `internal/tracks/pipeline_test.go`
- Create: `internal/guide/relationship_test.go`
- Create or modify: `internal/meeting/shared_context_test.go` (check for an existing file that already covers `gatherSharedContext`'s neighbours first)
- Modify: `internal/db/channel_stats_test.go` (create if absent)

**Interfaces:**
- Consumes: nothing from Task 1 at compile time; these tests exercise the read sites directly with namespaced fixtures.

**Why these tests matter:** every existing test in this area uses namespace-agnostic ids (`"C1"`, `"C100"`, `"U99"`) consistently on both sides of the comparison, so it passes identically whether or not the bug exists. The point of each test below is that the two sides come from *different* sources, exactly as they do in production, and carry the real `"1:Cxxx"` shape.

- [ ] **Step 1: `TestScoreChannel` fixtures move to namespaced ids.** In `internal/tracks/pipeline_test.go` (the suite starts near line 751) change the existing cases' ids to the `"1:C100"` / `"1:U456"` form, and add a case that goes through `buildRelevanceSignals` rather than hand-building the maps: construct a `db.Track` whose `ChannelIDs` is `["1:C100"]` and a `db.UserProfile` whose `StarredChannels`/`Reports` carry namespaced ids, call `buildRelevanceSignals(profile, tracks)`, then `scoreChannel("1:C100", topics, "1:U1", signals...)` and assert the +3 and +2 signals fire. Add the negative twin: the same call with a bare `"C100"` blob must score 0 for that channel — that asserts the very failure this branch fixes and would have caught it.
- [ ] **Step 2: Run them** — `go test ./internal/tracks/ -run TestScoreChannel > /tmp/gt.log 2>&1; echo "exit=$?"`.
- [ ] **Step 3: First test for `relationshipContext`** (`internal/guide/`, no test exists today). Build a `Pipeline` value with a `db.UserProfile` whose `Reports` is `["1:U456"]` and `Peers` is `["1:U789"]`, call `relationshipContext("1:U456")` → the DIRECT REPORT string; `("1:U789")` → PEER; `("1:U000")` → empty. Add the bare-blob twin (`Reports` = `["U456"]`, probe `"1:U456"`) asserting the empty result, so the frozen-blob hazard is pinned rather than folklore. Keep the assertions on a stable substring (`"DIRECT REPORT"`, `"YOUR PEER"`), not the full prose.
- [ ] **Step 4: Test `gatherSharedContext`'s participant match** in `internal/meeting/`: a track whose `Participants` JSON carries `"user_id":"1:U456"`, an attendee resolved to `"1:U456"` → the track is included; the same with a bare `"U456"` participant → excluded.
- [ ] **Step 5: Test `GetChannelStats`' track count** in `internal/db/`: seed a channel `1:C100`, a track with `channel_ids` `["1:C100"]`, call `GetChannelStats` and assert the row's track count is 1; seed a second channel whose only track is bare (`["C200"]`) and assert 0 — the join asymmetry, pinned.
- [ ] **Step 6: Run the affected packages** — `go test ./internal/tracks/ ./internal/guide/ ./internal/meeting/ ./internal/db/ > /tmp/gt.log 2>&1; echo "exit=$?"`.
- [ ] **Step 7: Commit.** `test: pin Slack-id namespacing at the six blob read sites`

---

### Task 3: Docs + full gate

**Files:**
- Modify: `CLAUDE.md` (the Slack Multi-Account section's "documented v1 identity-scoping decisions" bullet 2, which currently states JSON blobs are deliberately left bare)
- Modify: `docs/inventory/` only if a file there repeats that claim (grep first; do not invent a new contract number)

- [ ] **Step 1: Correct the stale claim.** CLAUDE.md's Slack Multi-Account section says JSON-embedded id columns "are NOT rewritten by the migration ... pre-migration blobs keep bare ids as frozen historical text". Migration 00054 changes that: update the bullet to say 00048 left them bare and 00054 backfilled them, and note what remains bare (memory-vault markdown, historical AI-generated text). Keep it to the existing bullet — no new contract, no new section.
- [ ] **Step 2: Full gate.** `gofmt -l . > /tmp/fmt.log 2>&1; echo "exit=$?"` (expect empty output), `go vet ./... > /tmp/vet.log 2>&1; echo "exit=$?"`, `go build ./... > /tmp/gb.log 2>&1; echo "exit=$?"`, `go test ./... > /tmp/gt-all.log 2>&1; echo "exit=$?"`. Swift is untouched, so no Desktop build is needed.
- [ ] **Step 3: Commit.** `docs: record the 00054 JSON-id backfill in the multi-account notes`

## Self-review notes

- Every confirmed finding from the audit maps to a migrated column (1,2,3,4,5) plus the sixth found separately in `channel_stats.go`; each gets a pinning test in Task 2.
- The migration is idempotent by construction (the GLOB guard), which is what makes the "run it twice" assertion meaningful rather than decorative.
- No schema change means the golden snapshot must not move — a moved snapshot is a signal of an accidental schema edit, not something to `-update`.
