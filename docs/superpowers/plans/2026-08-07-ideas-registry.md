# Ideas & Decisions Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A registry that auto-mines ideas and decisions out of Slack, meetings, Gmail and Jira (two-stage: cheap per-stream pre-digests → a throttled strong-tier consolidator), with owner triage, lifecycle, re-linking/resurfacing, per-item chat, and Target conversion.

**Architecture:** Stage 1 rides existing reads (Slack digest prompt + meeting recap prompt gain idea/decision extraction; new light-tier email/jira pre-digest passes write `stream_digests`; new bounded Jira comment sync). Stage 2 is a new `internal/ideas` pipeline + daemon phase (6h throttle) that consumes stage-1 output behind mechanical floors, validates every provenance ref, and applies ops in one transaction. Desktop gets an Ideas tab (master-detail + chat), MCP gets read tools.

**Tech Stack:** Go 1.25 (goose migrations, modernc.org/sqlite, cobra), SwiftUI/GRDB (macOS 14+), claude/codex CLI providers.

**Spec:** `docs/superpowers/specs/2026-08-07-ideas-registry-design.md` (read it first; contracts IDEA-01..04 are in §10).

## Global Constraints

- Branch: `feature/ideas-registry`. Worktree root: `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/tray-daemon-lifecycle` — run everything from there; verify `git branch --show-current` prints `feature/ideas-registry` before ANY commit.
- Everything committed to the repo (code, comments, docs, commit messages) is English.
- Next free migration number is **00050** (then 00051 etc. if a later task needs one — check `ls internal/db/migrations/ | tail -1` first).
- Every schema change: mirror into `internal/db/schema.sql`, add new tables to `TestAllTablesExist` (`internal/db/schema_contracts_test.go`), regenerate golden: `go test ./internal/db/ -run TestSchemaGolden -update`.
- New prompt ids must satisfy `internal/prompts/defaults_extra_test.go` invariants: entry in `Defaults`, `AllIDs`, `DefaultVersions[id]=1`, `Descriptions`, template starts with `%s` (Directive slot), template must NOT begin with `-`.
- Light-tier routing = the prompt's `digest.WithSource` tag added to BOTH `internal/digest/models.go` and `internal/codex/models.go` case lists. Absent from both = strong tier (default).
- SQLite `MaxOpenConns=1`: never do DB writes from a reader goroutine (see `internal/jira/sync.go:344`).
- Go checks per task: `go build ./... && go vet ./... && go test ./internal/<touched>/...`. Swift: `cd WatchtowerDesktop && swift build && swift test 2>&1 | tail -20; echo "exit=$?"` — capture the real exit code, never pipe through `tail` alone.
- Tests must not hardcode absolute dates (seed from `time.Now()` for window logic).
- Commit after each task with a conventional message; end commit bodies with the Claude trailer used on this branch.

---

### Task 1: Migration 00050 — registry tables, stage-1 tables, floors, enum expansion

**Files:**
- Create: `internal/db/migrations/00050_ideas_registry.sql`
- Modify: `internal/db/schema.sql` (mirror all changes), `internal/db/schema_contracts_test.go` (TestAllTablesExist: add `ideas`, `idea_mentions`, `stream_digests`, `jira_comments`)
- Regenerate: schema golden snapshot

**Interfaces:**
- Produces: tables `ideas`, `idea_mentions`, `stream_digests`, `jira_comments`; columns `digest_topics.ideas`, `workspace.ideas_digest_floor/ideas_stream_digest_floor/ideas_transcript_floor`, `google_accounts.ideas_email_floor`, `jira_accounts.ideas_jira_floor`; `targets.source_type` CHECK includes `'idea'`.

- [ ] **Step 1: Read the add-migration skill** (`.claude/skills/add-migration/SKILL.md`) and `internal/db/migrations/00002_*.sql`/`00003_*.sql` (the targets CHECK-expansion dance precedent) plus `00049_jira_accounts.sql` (NO TRANSACTION + PRAGMA foreign_keys=OFF pattern for table rebuilds).

- [ ] **Step 2: Write the migration.** Use `-- +goose NO TRANSACTION` + `PRAGMA foreign_keys = OFF;` (targets rebuild). Content:

```sql
-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

CREATE TABLE IF NOT EXISTS ideas (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    kind            TEXT NOT NULL CHECK(kind IN ('idea','decision','note')),
    title           TEXT NOT NULL,
    essence         TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'proposed'
                    CHECK(status IN ('proposed','active','rejected','not_now',
                                     'converted','dropped','merged','superseded','reversed')),
    source          TEXT NOT NULL DEFAULT 'mined' CHECK(source IN ('mined','owner')),
    snooze_until    TEXT NOT NULL DEFAULT '',
    needs_review    INTEGER NOT NULL DEFAULT 0,
    review_reason   TEXT NOT NULL DEFAULT '',
    similar_to_id   INTEGER,
    merged_into_id  INTEGER,
    superseded_by_id INTEGER,
    converted_target_id INTEGER,
    owner_rating    INTEGER NOT NULL DEFAULT 0,
    rating_comment  TEXT NOT NULL DEFAULT '',
    last_mention_at TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_ideas_status ON ideas(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_ideas_kind ON ideas(kind, status);

CREATE TABLE IF NOT EXISTS idea_mentions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner')),
    ref         TEXT NOT NULL DEFAULT '',
    quote       TEXT NOT NULL DEFAULT '',
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);

CREATE TABLE IF NOT EXISTS stream_digests (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK(source IN ('gmail','jira')),
    account_id   INTEGER NOT NULL,
    scope        TEXT NOT NULL DEFAULT '',
    period_from  TEXT NOT NULL,
    period_to    TEXT NOT NULL,
    topics_json  TEXT NOT NULL DEFAULT '[]',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);

CREATE TABLE IF NOT EXISTS jira_comments (
    account_id  INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key   TEXT NOT NULL,
    id          TEXT NOT NULL,
    author      TEXT NOT NULL DEFAULT '',
    body_text   TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT '',
    updated_at  TEXT NOT NULL DEFAULT '',
    synced_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_jira_comments_issue ON jira_comments(account_id, issue_key);

ALTER TABLE digest_topics ADD COLUMN ideas TEXT NOT NULL DEFAULT '[]';
ALTER TABLE workspace ADD COLUMN ideas_digest_floor INTEGER NOT NULL DEFAULT 0;
ALTER TABLE workspace ADD COLUMN ideas_stream_digest_floor INTEGER NOT NULL DEFAULT 0;
ALTER TABLE workspace ADD COLUMN ideas_transcript_floor INTEGER NOT NULL DEFAULT 0;
ALTER TABLE google_accounts ADD COLUMN ideas_email_floor REAL NOT NULL DEFAULT 0;
ALTER TABLE jira_accounts ADD COLUMN ideas_jira_floor TEXT NOT NULL DEFAULT '';
```

Then the `targets` CHECK-expansion: copy the full table-recreation dance from `internal/db/migrations/00003` — CREATE `targets_new` with the current column list from `internal/db/schema.sql:380-408` but `source_type` CHECK extended with `'idea'`; `INSERT INTO targets_new SELECT ... FROM targets;` DROP old; RENAME; recreate every `idx_targets_*` index verbatim from schema.sql. Finish with `PRAGMA foreign_keys = ON;`. Write the symmetric `-- +goose Down` (drop new tables/columns; targets dance back without `'idea'`).

- [ ] **Step 3: Mirror into `internal/db/schema.sql`** — new tables appended in a `-- Ideas & Decisions Registry` section; `digest_topics` gains the `ideas` column inline; `targets.source_type` CHECK gains `'idea'`; workspace/google_accounts/jira_accounts columns added inline with a `-- ideas registry floor` comment each.

- [ ] **Step 4: Add the four tables to `TestAllTablesExist`**, run `go test ./internal/db/ -run 'TestAllTablesExist|TestSchemaGolden' -update` then the full `go test ./internal/db/`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(db): ideas registry schema — registry, mentions, stream digests, jira comments (00050)`.

---

### Task 2: Go DB layer — `internal/db/ideas.go`

**Files:**
- Create: `internal/db/ideas.go`, `internal/db/ideas_test.go`
- Modify: `internal/db/digests.go` (DigestTopic.Ideas field + read/write), `internal/db/models.go` (DigestTopic struct)

**Interfaces (produces — later tasks depend on these exact signatures):**

```go
type Idea struct {
    ID int64; Kind, Title, Essence, Status, Source, SnoozeUntil string
    NeedsReview bool; ReviewReason string
    SimilarToID, MergedIntoID, SupersededByID, ConvertedTargetID sql.NullInt64
    OwnerRating int; RatingComment string
    LastMentionAt, CreatedAt, UpdatedAt string
}
type IdeaMention struct { ID, IdeaID int64; Source, Ref, Quote, Author, SaidAt, CreatedAt string }
type IdeaFilter struct { Kind, Status, Query string; Limit int }

func (db *DB) CreateIdeaTx(tx *sql.Tx, idea Idea) (int64, error)
func (db *DB) InsertIdeaMentionTx(tx *sql.Tx, m IdeaMention) error   // also bumps ideas.last_mention_at/updated_at
func (db *DB) SetIdeaNeedsReviewTx(tx *sql.Tx, id int64, reason string) error
func (db *DB) ListIdeas(f IdeaFilter) ([]Idea, error)
func (db *DB) GetIdea(id int64) (*Idea, error)                        // nil,nil on no row
func (db *DB) ListIdeaMentions(ideaID int64) ([]IdeaMention, error)   // ORDER BY said_at, id
func (db *DB) ListIdeasForPrompt() ([]Idea, error)  // status IN (proposed,active,not_now) OR updated_at >= now-60d
func (db *DB) ListIdeaVerdictExamples(limit int) ([]Idea, error)      // rated or rejected/dropped/active, newest first

func (db *DB) GetIdeasFloors() (digest, stream, transcript int64, err error)
func (db *DB) SetIdeasFloorsTx(tx *sql.Tx, digest, stream, transcript int64) error

type StreamDigest struct { ID int64; Source string; AccountID int64; Scope, PeriodFrom, PeriodTo, TopicsJSON, CreatedAt string }
func (db *DB) InsertStreamDigest(d StreamDigest) (int64, error)
func (db *DB) ListStreamDigestsAfter(floor int64) ([]StreamDigest, error)

type JiraComment struct { AccountID int64; IssueKey, ID, Author, BodyText, CreatedAt, UpdatedAt string }
func (db *DB) UpsertJiraComments(comments []JiraComment) error        // ON CONFLICT(account_id, id) DO UPDATE
func (db *DB) ListJiraCommentsSince(accountID int64, issueKeys []string, sinceISO string) ([]JiraComment, error)

type DigestTopicForIdeas struct { TopicID int64; ChannelID, ChannelName string; PeriodTo float64; Ideas, Decisions string /* JSON */ }
func (db *DB) ListDigestTopicIdeasAfter(floor int64) ([]DigestTopicForIdeas, error)
// JOIN digests d ON dt.digest_id=d.id LEFT JOIN channels c; WHERE dt.id > ? AND (dt.ideas != '[]' OR dt.decisions != '[]') AND d.type='channel' ORDER BY dt.id

type TranscriptForIdeas struct { ID int64; EventID, Title, RecapJSON, CreatedAt string }
func (db *DB) ListTranscriptsForIdeasAfter(floor int64) ([]TranscriptForIdeas, error)
// meeting_transcripts id > floor ORDER BY id; RecapJSON = COALESCE(meeting_recaps.recap_json for event_id, summary_json)

func (db *DB) CountIdeasForReview() (int, error)  // status='proposed' OR needs_review=1
```

Also: `DigestTopic` struct in `models.go` gains `Ideas string` (JSON), `InsertDigestTopics`/`GetDigestTopics*` read/write the new column (default `'[]'`).

- [ ] **Step 1: Write failing tests** in `internal/db/ideas_test.go` (open in-memory DB via the package's existing test helper — see `internal/db/memory_test.go` for the pattern): create idea in tx → Get/List round-trip; InsertIdeaMentionTx bumps `last_mention_at`; ListIdeasForPrompt includes a 30-day-old `dropped` idea (seeded from `time.Now().AddDate(0,0,-30)`) and excludes a 90-day-old one; floors get/set round-trip; UpsertJiraComments idempotent on same id; ListDigestTopicIdeasAfter returns only topics with non-empty ideas/decisions above the floor; ListTranscriptsForIdeasAfter resolves recap collision (meeting_recaps row wins over summary_json).
- [ ] **Step 2: Run** `go test ./internal/db/ -run TestIdeas` — expect FAIL (undefined functions).
- [ ] **Step 3: Implement** `internal/db/ideas.go` following the house error-wrapping style (`fmt.Errorf("creating idea: %w", err)`); `ListIdeas` builds WHERE dynamically (kind/status equality, query as `title LIKE ? OR essence LIKE ?` with `%`-wrapped arg, mention-quote search via `EXISTS (SELECT 1 FROM idea_mentions m WHERE m.idea_id=ideas.id AND m.quote LIKE ?)`), default limit 200. Wire `DigestTopic.Ideas` through `models.go` + `digests.go` (INSERT gains the column; SELECTs gain it with COALESCE for pre-migration rows — column exists post-00050, so plain select is fine).
- [ ] **Step 4: Run** `go test ./internal/db/` — expect PASS. **Step 5: Commit** `feat(db): ideas registry queries + digest topic ideas column`.

---

### Task 3: Config block + prompt registration (3 new prompts)

**Files:**
- Modify: `internal/config/config.go` (IdeasConfig struct + Config field + SetDefaults), `internal/config/defaults.go` (constants), `internal/prompts/store.go` (id constants), `internal/prompts/defaults.go` (templates + 4 maps), `internal/digest/models.go` + `internal/codex/models.go` (light-tier routing for the two stage-1 prompts)

**Interfaces:**
- Produces: `cfg.Ideas.Enabled` (default true), `cfg.Ideas.MineIntervalHours` (default 6), `cfg.Ideas.MaxCommentIssuesPerSync` (default 50), `cfg.Ideas.MaxPromptChars` (default 60000); prompt ids `prompts.IdeasDigestEmail = "ideas.digest_email"`, `prompts.IdeasDigestJira = "ideas.digest_jira"`, `prompts.IdeasConsolidate = "ideas.consolidate"`.

- [ ] **Step 1:** Add `IdeasConfig` (copy `InboxConfig` shape, `internal/config/config.go:52`), field `Ideas IdeasConfig \`mapstructure:"ideas"\`` in `Config`, `v.SetDefault("ideas.enabled", true)` etc. in `Load`, constants in `defaults.go`.
- [ ] **Step 2:** Register the three prompts per the add-ai-prompt skill (`.claude/skills/add-ai-prompt/SKILL.md`). Templates (all start with `%s` Directive slot):
  - `ideas.digest_email` (light): input = numbered email threads (`[n] subject (gmail:<acct>:<thread>): participants — excerpt`); output JSON `{"topics":[{"title","summary","ideas":[{"text","author","ref"}],"decisions":[{"text","author","ref"}]}]}` where `ref` MUST be copied verbatim from a `gmail:` tag in the input. Instruct: an idea is a proposal of something new not yet decided; a decision is a made choice; extract conservatively, empty arrays are fine.
  - `ideas.digest_jira` (light): same output contract, input = numbered issues (`[n] KEY summary — status change — description excerpt — comments`), `ref` = the bare issue key from the input.
  - `ideas.consolidate` (strong, NOT in the light lists): input sections `=== REGISTRY ===` (id | kind | status | title — essence), `=== OWNER PREFERENCES ===`, `=== NEW MATERIAL ===` (per-source blocks, every line carrying an explicit `ref=`); output `{"ops":[...]}` per the spec §7 contract (`new_idea`, `new_decision`, `attach_mention` with `idea_id`, optional `similar_to`); rules: attach to an existing registry item instead of duplicating; only propose genuinely new items; copy `ref`/`author`/`said_at` verbatim from the material lines; never invent refs.
- [ ] **Step 3:** Add `"ideas.digest_email", "ideas.digest_jira"` to BOTH light-tier switches (`internal/digest/models.go:12`, `internal/codex/models.go`). Run `go test ./internal/prompts/ ./internal/config/ ./internal/digest/ ./internal/codex/` — expect PASS (the defaults_extra_test invariants validate registration).
- [ ] **Step 4: Commit** `feat(ideas): config block and prompt registration`.

---

### Task 4: Bounded Jira comment sync

**Files:**
- Modify: `internal/jira/client.go` (GetIssueComments), `internal/jira/sync.go` (collect changed keys + fetch), `internal/jira/sync_test.go`
- Test: `internal/jira/client_test.go` (existing test mux pattern — see `reference_test_mux_pattern`)

**Interfaces:**
- Consumes: `db.UpsertJiraComments` (Task 2), `cfg` not visible here — cap passed in: `Syncer.SetCommentSyncLimit(n int)` (0 = disabled).
- Produces: comments of issues touched by an incremental sync land in `jira_comments`.

- [ ] **Step 1: Failing client test:** httptest mux serving `/rest/api/3/issue/PROJ-1/comment` with a paginated payload `{"comments":[{"id":"10001","author":{"displayName":"A"},"body":{...adf...},"created":"...","updated":"..."}],"startAt":0,"maxResults":50,"total":1}`; assert `GetIssueComments(ctx, "PROJ-1")` returns 1 comment with ADF flattened to plain text.
- [ ] **Step 2: Implement** in `client.go`:

```go
type IssueComment struct {
    ID      string `json:"id"`
    Author  struct{ DisplayName string `json:"displayName"` } `json:"author"`
    Body    interface{} `json:"body"`
    Created string `json:"created"`
    Updated string `json:"updated"`
}
func (c *Client) GetIssueComments(ctx context.Context, key string) ([]IssueComment, error)
```

Paginate with `startAt`/`maxResults=50` via `getWithQuery` until `startAt+len >= total` (the `FetchAllBoards` shape). Body text: reuse `extractDescriptionText` (it already handles string/ADF).

- [ ] **Step 3: Syncer hook.** In `syncWithJQL`'s writer loop collect `changedKeys = append(changedKeys, dbIssues[i].Key)`; change signature to `syncWithJQL(ctx, jql, boardID) (int, []string, error)` (update both callers: `Sync`, `InitialLoad` — InitialLoad ignores the keys, comments are not backfilled). In `Sync`'s per-project loop, after a successful `syncWithJQL`, call `s.syncComments(ctx, changedKeys)`: cap at `s.commentSyncLimit` keys (newest last — take the tail; log the dropped count), for each key `GetIssueComments` → map to `db.JiraComment{AccountID: s.accountID, IssueKey: key, ...}` → one `UpsertJiraComments` per issue. `errors.Is(err, ErrAuthRevoked)` propagates; any other per-issue error logs and continues. All DB writes happen after the page loop (MaxOpenConns=1 rule).
- [ ] **Step 4:** Sync test: extend the existing sync test mux with the comment endpoint; assert comments rows exist after `Sync`, and that with limit 1 and 2 changed issues only the newest issue's comments were fetched. Run `go test ./internal/jira/`. **Step 5:** Wire the cap in `cmd/sync.go` `wireJiraSyncers`: `syncer.SetCommentSyncLimit(cfg.Ideas.MaxCommentIssuesPerSync)` gated on `cfg.Ideas.Enabled`. **Step 6: Commit** `feat(jira): bounded comment sync for recently updated issues`.

---

### Task 5: Slack digest ideas (stage 1)

**Files:**
- Modify: `internal/digest/pipeline.go` (Topic struct + persistence), `internal/prompts/defaults.go` (digest.channel + digest.channel_batch templates: add ideas extraction; bump `DefaultVersions` for both), `internal/digest/pipeline_test.go`

**Interfaces:**
- Produces: `digest.Topic.Ideas []IdeaCandidate` where `type IdeaCandidate struct { Text string `json:"text"`; By string `json:"by"`; MessageTS string `json:"message_ts"` }`; persisted JSON in `digest_topics.ideas`.

- [ ] **Step 1: Failing test:** unmarshal a digest AI response containing `"ideas":[{"text":"try X","by":"U1","message_ts":"123.45"}]` inside a topic → assert `result.Topics[0].Ideas[0].Text == "try X"`; and a response WITHOUT the field parses fine (empty slice). Assert the topics-persistence path writes the JSON to `digest_topics.ideas` (use the existing store-digest test setup in `pipeline_extra_test.go` as the template).
- [ ] **Step 2: Implement:** add `IdeaCandidate` next to `Decision` (pipeline.go:78); `Topic.Ideas []IdeaCandidate \`json:"ideas"\``; in the store block (pipeline.go:1328) marshal `t.Ideas` into `db.DigestTopic.Ideas`. Prompt: in `defaultDigestChannel` (and the batch variant) add an `ideas` instruction next to `decisions`: proposals of something new that was NOT decided — feature ideas, process suggestions, "what if" — with the proposer and message_ts; explicitly "empty array when none; do not list decisions here". Bump both `DefaultVersions` entries (+1 each) so `Seed()` upgrades installed rows.
- [ ] **Step 3:** `go test ./internal/digest/` — PASS. **Step 4: Commit** `feat(digest): extract idea candidates per topic (stage-1 for ideas registry)`.

---

### Task 6: Meeting recap ideas (stage 1)

**Files:**
- Modify: `internal/meeting/recap.go` (RecapResult + trim), `internal/prompts/defaults.go` (meeting.recap template + version bump), `internal/meeting/recap_test.go`

**Interfaces:**
- Produces: `meeting.RecapResult.Ideas []string \`json:"ideas"\`` (decisions already exist as `KeyDecisions`).

- [ ] **Step 1: Failing test:** recap JSON with `"ideas":["idea one",""]` parses and trims to `["idea one"]`; recap without the field → empty. Follow existing recap tests' generator-stub pattern.
- [ ] **Step 2: Implement:** add the field, `res.Ideas = trimNonEmpty(raw.Ideas)` in both `GenerateRecap` and `GenerateTranscriptRecap`; extend the `meeting.recap` template with an `ideas` array ("proposals raised but not decided; empty when none") and bump its `DefaultVersions` entry.
- [ ] **Step 3:** `go test ./internal/meeting/` — PASS. **Step 4: Commit** `feat(meeting): recap extracts idea candidates (stage-1 for ideas registry)`.

---

### Task 7: `internal/ideas` package — pipeline skeleton + email/jira pre-digest passes

**Files:**
- Create: `internal/ideas/pipeline.go`, `internal/ideas/email_digest.go`, `internal/ideas/jira_digest.go`, `internal/ideas/email_digest_test.go`, `internal/ideas/jira_digest_test.go`

**Interfaces:**
- Consumes: `db.ListGoogleAccounts`, `db.ListGmailThreadsForExtract(accountID, sinceTS, limit)` + `db.GmailExtractMessage` (internal/db/memory.go:1497), `db.ListEnabledJiraAccounts`, `db.ListJiraCommentsSince`, `db.InsertStreamDigest`, prompt ids from Task 3, `digest.Generator`.
- Produces:

```go
package ideas
type Pipeline struct { /* db, cfg, generator, logger, promptStore, usage accumulators — copy internal/inbox/pipeline.go:123 shape */ }
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline
func (p *Pipeline) SetPromptStore(store *prompts.Store)
func (p *Pipeline) AccumulatedUsage() (int, int, float64, int)
func (p *Pipeline) Run(ctx context.Context) (proposed int, err error) // email pass → jira pass → consolidate (Task 8)
func (p *Pipeline) runEmailDigests(ctx context.Context) error
func (p *Pipeline) runJiraDigests(ctx context.Context) error
```

- New per-account floor accessors in `internal/db/`: `IdeasEmailFloor(accountID int64) (float64, error)` / `SetIdeasEmailFloor(accountID int64, ts float64) error` (google_accounts, copy `MemoryGmailWatermark` shape, memory.go:1191) and `IdeasJiraFloor(accountID int64) (string, error)` / `SetIdeasJiraFloor(accountID int64, ts string) error` (jira_accounts) — put them in `internal/db/ideas.go`.

- [ ] **Step 1: Failing tests.** Email: fake generator returning a fixed topics JSON; seed 2 gmail threads; assert one `stream_digests` row with `source='gmail'`, refs preserved, and `ideas_email_floor` advanced to the max thread ts; on generator error assert NO row and floor unchanged (IDEA-01 spirit); with zero new threads assert clean no-op (degenerate-input rule). Jira: seed changed issues + comments; same assertions with `source='jira'`, scope=project key, `ideas_jira_floor` advanced to newest issue `updated_at`.
- [ ] **Step 2: Implement.**
  - Email pass per account (skip `!acct.GmailEnabled`): floor==0 → initialize to current max internal_date and skip (no backfill — the memory jira_ingest.go:80 precedent); else `ListGmailThreadsForExtract(acct.ID, floor, 500)` → group by thread (borrow the compact grouping loop shape from `internal/memory/gmail_extract.go:72` — do NOT import memory; write a local ~30-line `groupThreads`) → render numbered block with `(gmail:%d:%s)` tags → one `Generate(digest.WithSource(ctx,"ideas.digest_email"), system, userBlock, "")` per account → `prompts.ExtractJSONObject` + unmarshal into `streamTopics{Topics []streamTopic}` where `streamTopic{Title, Summary string; Ideas, Decisions []streamCandidate}` and `streamCandidate{Text, Author, Ref string}` → drop any candidate whose Ref is not in the rendered thread-tag set (validate at stage 1 too) → `InsertStreamDigest` → `SetIdeasEmailFloor` ONLY after successful insert.
  - Jira pass per enabled account: floor=="" → initialize to `time.Now().UTC().Format(time.RFC3339)` and skip; else query issues with `updated_at > floor` (add `db.ListJiraIssuesUpdatedSince(accountID int64, sinceISO string, limit int) ([]JiraIssue, error)` to `internal/db/ideas.go` — plain SELECT on jira_issues ORDER BY updated_at ASC LIMIT 300), group per project, fetch their comments via `ListJiraCommentsSince`, render block with bare issue keys as refs, one call per account (all projects in one block, `=== PROJECT X ===` separators), validate refs against the issue-key set, insert one row per account (`scope=''`, projects inside topics), advance floor to the max consumed `updated_at`.
  - Both passes: nil-generator guard returns nil (the inbox pipeline.go:253 pattern); per-account errors log and continue to the next account, returning the first error at the end.
- [ ] **Step 3:** `go test ./internal/ideas/` — PASS. **Step 4: Commit** `feat(ideas): email and jira pre-digest passes (stage-1)`.

---

### Task 8: Consolidator (stage 2) — the heart

**Files:**
- Create: `internal/ideas/consolidate.go`, `internal/ideas/consolidate_test.go`, `internal/ideas/preferences.go`

**Interfaces:**
- Consumes: Task 2 DB API, Task 3 `ideas.consolidate` prompt, stage-1 tables.
- Produces: `func (p *Pipeline) runConsolidate(ctx context.Context) (int, error)` called from `Run`; exported for CLI: `Run` returns total proposed.

- [ ] **Step 1: Failing tests** (table-driven, fake generator):
  1. `new_idea` op with a valid slack ref → `ideas` row status=proposed + mention row; floors advanced to consumed ids.
  2. Op with invented ref → mention dropped; op with ALL mentions invented → op dropped, `refsRejected` counter incremented, nothing written for it (IDEA-02).
  3. `attach_mention` to an `active` idea → mention added, `last_mention_at` bumped, status unchanged.
  4. `attach_mention` to a `rejected` idea → `needs_review=1` + `review_reason` set, status still `rejected` (IDEA-04).
  5. `attach_mention` to a `merged` idea → mention lands on `merged_into_id` target.
  6. Generator error → no rows written, floors unchanged (IDEA-01).
  7. Malformed JSON → same as 6.
  8. Zero new material → generator NOT called, clean no-op.
  9. Input-cap truncation: with `MaxPromptChars` tiny and 2 digest topics, only topic 1 is included and the digest floor advances only past topic 1.
- [ ] **Step 2: Run tests** — FAIL (undefined). 
- [ ] **Step 3: Implement.** Structure:

```go
type consolidateOp struct {
    Op        string          `json:"op"`
    Title     string          `json:"title"`
    Essence   string          `json:"essence"`
    IdeaID    int64           `json:"idea_id"`
    SimilarTo int64           `json:"similar_to"`
    Mentions  []mentionInput  `json:"mentions"`
    Mention   *mentionInput   `json:"mention"`
}
type mentionInput struct { Source, Ref, Quote, Author, SaidAt string }
type consolidateInput struct {
    topics      []db.DigestTopicForIdeas
    streams     []db.StreamDigest
    transcripts []db.TranscriptForIdeas
    maxTopicID, maxStreamID, maxTranscriptID int64
    validRefs   map[string]string // ref -> source ("slack"|"meeting"|"gmail"|"jira")
    block       string            // rendered NEW MATERIAL section
}
```

  - `gatherInput`: read floors; list the three sources; build the material block **respecting `cfg.Ideas.MaxPromptChars`** — append whole units (topic / stream digest / transcript) until the budget is hit, tracking per-source max consumed id over *included* units only. Transcript nuance (spec §7): a transcript with no recap JSON yet and `created_at` within 48h of now stops transcript consumption at the row before it (recap may still arrive); older recap-less transcripts are skipped (counted, floor moves past). Slack refs are `"<channel_id>|<message_ts>"` (message_ts from the candidate); meeting refs are `fmt.Sprintf("transcript:%d", t.ID)`; gmail refs come verbatim from topics_json (`gmail:<acct>:<thread>`); jira refs are issue keys. Every rendered candidate line ends with ` ref=<ref>`.
  - `registrySection`: `ListIdeasForPrompt()` rendered as `#<id> [<kind>/<status>] <title> — <essence>`.
  - `preferences.go`: `buildPreferencesBlock(database *db.DB) string` — `ListIdeaVerdictExamples(20)`, render `LIKED/APPROVED:` and `DISLIKED/REJECTED:` lists (title + rating_comment); empty string when none.
  - AI call: `p.generator.Generate(digest.WithSource(ctx, "ideas.consolidate"), system, "Consolidate the new material into the registry.", "")` where system = `fmt.Sprintf(tmpl, prompts.Directive(lang), registry, prefs, materialBlock)`; parse via `prompts.ExtractJSONObject`.
  - `applyOps`: validate first, THEN one `p.db.BeginTx` — parse-before-mutate (the compose.go:123 precedent). For each op: filter mentions through `validRefs` (source must match too); `new_idea|new_decision` with ≥1 surviving mention → `CreateIdeaTx` (kind idea|decision, status proposed, source mined, `similar_to_id` when SimilarTo>0 and exists) + mentions; `attach_mention` → resolve target (follow `merged_into_id` one hop), insert mention, and if target status ∈ {not_now, dropped, rejected} → `SetIdeaNeedsReviewTx(tx, id, "brought up again: "+shortRef)`. Finish with `SetIdeasFloorsTx(tx, maxTopicID, maxStreamID, maxTranscriptID)` and commit. Any error → rollback, floors untouched.
- [ ] **Step 4:** `go test ./internal/ideas/` — PASS. **Step 5: Commit** `feat(ideas): consolidator — registry ops with ref validation and honest floors`.

---

### Task 9: Daemon phase + cmd wiring + CLI

**Files:**
- Modify: `internal/daemon/daemon.go` (field, setter, phase, runSync call, throttle persistence), `cmd/sync.go` (wire), 
- Create: `cmd/ideas.go`, `cmd/ideas_test.go`

**Interfaces:**
- Consumes: `ideas.New`, `Pipeline.Run`, `cfg.Ideas.*`.
- Produces: `d.SetIdeasPipeline(p *ideas.Pipeline)`; CLI `watchtower ideas mine`, `watchtower ideas list [--kind K] [--status S]`.

- [ ] **Step 1: Daemon.** Add `ideasPipe *ideas.Pipeline` + `lastIdeas time.Time` fields, `SetIdeasPipeline` setter, `phaseIdeas(ctx)` copying `phasePeopleCards` (daemon.go:744) with throttle `time.Duration(d.config.Ideas.MineIntervalHours) * time.Hour`, `trackedPipelineRun("ideas", ...)`, and `lastIdeasPath()`/`loadLastIdeas()`/`saveLastIdeas()` (`last_ideas.txt`, the last_people.txt trio at daemon.go:957). Call `d.loadLastIdeas()` next to `loadLastPeople` (daemon.go:244) and `d.phaseIdeas(ctx)` in `runSync` right after `d.phaseInbox(ctx)`.
- [ ] **Step 2: Wire** in `cmd/sync.go` inside the `cfg.Digest.Enabled` block: 

```go
if cfg.Ideas.Enabled {
    ideasPipe := ideas.New(database, cfg, gen, logger)
    ideasPipe.SetPromptStore(prompts.New(database, nil))
    d.SetIdeasPipeline(ideasPipe)
}
```

- [ ] **Step 3: CLI** `cmd/ideas.go` copying the `cmd/memory.go` cobra shape (group + subcommands + `memoryConfigAndDB`-style helper — reuse an existing config/db helper if one is exported, else write `ideasConfigAndDB`). `mine`: build generator via `cliGenerator(cfg)`, run `pipe.Run(ctx)`, print `proposed=%d` + accumulated usage. `list`: `--kind`, `--status` flags → `database.ListIdeas(db.IdeaFilter{...})` → tab-printed table (id, kind, status, title, last_mention_at) via `cmd.OutOrStdout()`.
- [ ] **Step 4:** Test: `cmd/ideas_test.go` — `ideas list` against a seeded temp DB prints the seeded title (follow an existing cmd test for the setup pattern, e.g. `cmd/slack_test.go`). Run `go build ./... && go test ./cmd/ ./internal/daemon/`. **Step 5: Commit** `feat(ideas): daemon phase with 6h throttle + ideas CLI`.

---

### Task 10: MCP read tools

**Files:**
- Create: `internal/mcp/ideas.go`, `internal/mcp/ideas_test.go`
- Modify: `internal/mcp/server.go` (`registerIdeas(srv.s, database)` in NewServer)

**Interfaces:**
- Consumes: `db.ListIdeas`, `db.GetIdea`, `db.ListIdeaMentions`.
- Produces: MCP tools `list_ideas{kind?,status?,query?,limit?}`, `get_idea{id}`.

- [ ] **Step 1:** Copy the `internal/mcp/jira.go:18` registration shape verbatim (args structs with `jsonschema` tags, `listLimit`, `validateEnum` for kind/status, `jsonListResult`/`jsonResult`/`errResult`). `get_idea` returns the idea plus its mentions in one object.
- [ ] **Step 2:** Test with the package's existing in-process client harness (see how `internal/mcp` tests call tools today; mirror one transcript-tool test). Run `go test ./internal/mcp/`. **Step 3: Commit** `feat(mcp): list_ideas and get_idea tools`.

---

### Task 11: Desktop — model, queries, TestDatabase schema

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/Idea.swift`, `Sources/Models/IdeaMention.swift`, `Sources/Database/Queries/IdeaQueries.swift`, `Tests/IdeaQueriesTests.swift`
- Modify: `Tests/Helpers/TestDatabase.swift` (schema: `ideas` + `idea_mentions` CREATE TABLE copied from `internal/db/schema.sql`; fixtures `insertIdea`/`insertIdeaMention` in the house all-defaults `@discardableResult` style)

**Interfaces:**
- Produces:

```swift
struct Idea: FetchableRecord, Identifiable, Equatable {
    let id: Int; let kindRaw: String; let title: String; let essence: String
    let statusRaw: String; let source: String; let snoozeUntil: String
    let needsReview: Bool; let reviewReason: String
    let similarToID: Int?; let mergedIntoID: Int?; let supersededByID: Int?; let convertedTargetID: Int?
    let ownerRating: Int; let ratingComment: String
    let lastMentionAt: String; let createdAt: String; let updatedAt: String
    enum Kind: String { case idea, decision, note }
    enum Status: String { case proposed, active, rejected, notNow = "not_now", converted, dropped, merged, superseded, reversed }
    var kind: Kind { Kind(rawValue: kindRaw) ?? .idea }
    var status: Status { Status(rawValue: statusRaw) ?? .proposed }
    var isForReview: Bool { status == .proposed || needsReview }
}
enum IdeaQueries {
    static func fetchList(_ db: Database, kind: String?, status: String?, query: String?, limit: Int) throws -> [Idea]
    static func fetchForReview(_ db: Database) throws -> [Idea]      // proposed OR needs_review=1, ORDER BY updated_at DESC
    static func fetchOne(_ db: Database, id: Int) throws -> Idea?
    static func fetchMentions(_ db: Database, ideaID: Int) throws -> [IdeaMention]
    static func countForReview(_ db: Database) throws -> Int
    static func setStatus(_ db: Database, id: Int, status: String) throws          // bumps updated_at, clears needs_review
    static func snooze(_ db: Database, id: Int, until: String?) throws             // status='not_now'
    static func merge(_ db: Database, id: Int, into targetID: Int) throws          // re-parent mentions, status='merged', merged_into_id
    static func supersede(_ db: Database, id: Int, by newID: Int?) throws
    static func setRating(_ db: Database, id: Int, rating: Int, comment: String) throws
    static func createManual(_ db: Database, kind: String, title: String, essence: String) throws -> Int64
    // status='active', source='owner', plus an 'owner' mention row carrying the essence text
    static func markConverted(_ db: Database, id: Int, targetID: Int64) throws
}
```

- [ ] **Step 1: Failing tests** (`TestDatabase.create()`, follow `Tests/SituationQueriesTests.swift`): list filtering by kind/status/query (query matches a mention quote), review count, merge re-parents mentions and follows the link, createManual creates the owner mention, setStatus clears needs_review. Run `swift test --filter IdeaQueriesTests` → FAIL.
- [ ] **Step 2: Implement** models (mirror `Sources/Models/Situation.swift` — `init(row: Row)` with `?? ` defaults, `as Int?` for nullable FKs) and queries (raw-SQL enum-of-statics like `SituationQueries.swift`; every write bumps `updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')`).
- [ ] **Step 3:** `cd WatchtowerDesktop && swift build > /tmp/sb.log 2>&1; echo $?` then `swift test --filter IdeaQueriesTests` → PASS. **Step 4: Commit** `feat(desktop): idea models and queries`.

---

### Task 12: Desktop — ViewModel, sidebar tab, badge

**Files:**
- Create: `Sources/ViewModels/IdeasViewModel.swift`, `Tests/IdeasViewModelTests.swift`
- Modify: `Sources/App/SidebarDestination.swift` (case `ideas`, title "Ideas", icon `lightbulb`), `Sources/App/SidebarSection.swift` (add `.ideas` to `.today` items after `.inbox`), `Sources/App/Navigation.swift` (detailView case), `Sources/App/AppState.swift` (`ideasViewModel` + `initIdeas(dbManager:)` called from `initialize()`), `Sources/ViewModels/SidebarCountsViewModel.swift` (ideasCount: `Counts` field, fetch via `(try? IdeaQueries.countForReview(db)) ?? 0`, `"ideas"` in tracked tables), `Sources/Views/Sidebar/SidebarView.swift` (`count(for:)` case + badge color amber/orange)

**Interfaces:**
- Produces: `@MainActor @Observable final class IdeasViewModel` — copy `DashboardViewModel.swift` structure: `var reviewItems: [Idea]`, `var registryItems: [Idea]`, `var selectedID: Int?`, `var kindFilter: String?`, `var statusFilter: String?`, `var searchText: String`, `load()`, `refresh()`, `startObserving()` (ValueObservation on `SELECT COUNT(*) FROM ideas` + 30s poll), `reconcileSelection()`, and action methods `approve/reject/activate/notNow/drop/merge/supersede/reverse/setRating/createManual/convertToTarget` each as `dbManager.dbPool.write { IdeaQueries... }` + `load()`.
- `convertToTarget(idea:)`: mirror the Dashboard's convert flow — read `DashboardViewModel`'s create-target implementation and reuse the same queries with `source_type: "idea"`, `source_id: String(idea.id)`, then `IdeaQueries.markConverted`; navigate via the same `appState.navigateToTarget` hook Dashboard uses.

- [ ] **Step 1: Failing VM tests:** seed proposed + active + rejected-with-needs_review ideas → `load()` splits review vs registry correctly; `approve` moves item out of review and keeps selection valid; badge count matches `countForReview`. (`TestDatabase.createDatabaseManager()`, `@MainActor` test class.)
- [ ] **Step 2: Implement** VM + all six modified files (follow `.claude/skills/add-desktop-feature/SKILL.md` "Navigation wiring (4 spots)"; `SidebarCountsViewModel` tolerates pre-migration schema via `(try? ...) ?? 0` like `memoryDisputedCount`).
- [ ] **Step 3:** `swift build && swift test --filter 'IdeasViewModel|SidebarCounts'` → PASS. **Step 4: Commit** `feat(desktop): ideas tab navigation, view model, badge`.

---

### Task 13: Desktop — views (master-detail, actions, create sheet)

**Files:**
- Create: `Sources/Views/Ideas/IdeasView.swift`, `Sources/Views/Ideas/IdeaRow.swift`, `Sources/Views/Ideas/IdeaDetailPane.swift`, `Sources/Views/Ideas/IdeaCreateSheet.swift`

**Interfaces:**
- Consumes: `IdeasViewModel` (Task 12), `IdeaChatViewModel` (Task 14 — the detail pane embeds the Discuss section; in THIS task put a placeholder `EmptyView()` marked with a `// Discuss section added in the chat task` comment ONLY if Task 14 runs later; if executing sequentially, Task 14 lands first — check).

Layout (copy `DashboardView.swift:` `HSplitView` + `List(selection:)` + `.id(item.id)` on the detail call site — the leak-avoidance comment at DashboardView.swift:175 applies verbatim):
- `IdeasView`: toolbar (kind filter `Picker`, status filter, `TextField` search, `+` button opening `IdeaCreateSheet`), left list with two `Section`s ("For review" from `vm.reviewItems`, "Registry" from `vm.registryItems`), right `IdeaDetailPane(idea:...)` with injected action closures (the `SituationReviewPane` closure-injection pattern: `onApprove`, `onReject`, `onActivate`, `onNotNow: (Date?) -> Void`, `onDrop`, `onMerge: (Int) -> Void`, `onConvert`, `onSupersede`, `onReverse`, `onRating: (Int, String) -> Void`).
- `IdeaRow`: kind glyph (`lightbulb` / `checkmark.seal` / `note.text`), 2-line title, needs_review orange dot, trailing relative date.
- `IdeaDetailPane`: header (title, kind+status badges, review_reason banner when needs_review), essence text, similar-to link row when `similarToID != nil` ("Looks similar to #N" + Merge button), rating bar (👍/👎 + comment TextField — the SituationReviewPane actionBar shape), status-dependent action bar, mentions chronology (quote bubble + author + `Text(date, style:.relative)` + Link built per source: slack `permalinkFor` if available else plain, jira issue URL via `JiraConfigHelper.readSiteURL()`, gmail/meeting plain labels), Discuss section at the bottom.
- `IdeaCreateSheet`: kind picker (idea/note/decision), title field, essence editor, Create → `vm.createManual`.
- `.onAppear { vm.refresh() }` on `IdeasView` (cross-process daemon writes rule).

- [ ] **Step 1: Implement** the four views. **Step 2:** `swift build` clean; run the full `swift test` to catch regressions. **Step 3: Commit** `feat(desktop): ideas master-detail UI`.

---

### Task 14: Desktop — Idea Discuss chat

**Files:**
- Create: `Sources/ViewModels/IdeaChatViewModel.swift`, `Sources/Views/Ideas/IdeaDiscussSection.swift`, `Tests/IdeaChatViewModelTests.swift`
- Modify: `Sources/Views/Ideas/IdeaDetailPane.swift` (embed section + input bar)

**Interfaces:**
- Produces: `IdeaChatViewModel` — the deliberate house-pattern copy of `SituationChatViewModel.swift` (header comment marks it as such): `contextType: "idea"`, `contextID: String(idea.id)`, conversation title `"Idea: \(idea.title.prefix(60))"`. `nonisolated static func ideaContextBlock(_ idea: Idea, mentions: [IdeaMention]) -> String` renders `=== IDEA ===` (kind, status, title, essence) + `=== MENTIONS ===` (author, date, quote, ref); `buildSystemPrompt` reuses the owner-profile pieces the situation VM uses and points the model at `list_ideas`/`get_idea` MCP tools. Input bar docks OUTSIDE the pane's ScrollView (the `SituationDiscussInputBar` nested-NSScrollView rule — copy that component's placement).

- [ ] **Step 1: Failing test:** with `MockClaudeService`, first send creates a `chat_conversations` row with `context_type='idea'`; a second VM for the same idea reuses it; context block contains the essence and a mention quote. (Mirror `Tests/SituationChatViewModelTests.swift`.)
- [ ] **Step 2: Implement** VM + section + embed. **Step 3:** `swift test --filter IdeaChat` → PASS, then full `swift test`. **Step 4: Commit** `feat(desktop): per-idea discuss chat`.

---

### Task 15: Inventory, docs, guide

**Files:**
- Create: `docs/inventory/ideas.md`
- Modify: `docs/inventory/README.md` (module mapping row), `CLAUDE.md` (feature note section, mirroring the house style — what/where/contracts, ~15 lines), `docs/app-guide.md` (Ideas tab section — the guide is injected into the chatbot prompt; user rule requires updating it on UI changes)

- [ ] **Step 1:** Write `docs/inventory/ideas.md` with IDEA-01..04 verbatim from the spec §10, each with a "Guarded by" line naming the tests from Tasks 7/8 (exact test function names as implemented).
- [ ] **Step 2:** CLAUDE.md note under Feature Notes: two-stage architecture, floors, table names, prompt ids, config keys, tab, contracts pointer.
- [ ] **Step 3: Commit** `docs: ideas registry inventory, feature notes, app guide`.

---

### Task 16: Final verification & PR

- [ ] **Step 1:** Full local gate: `go build ./... && go vet ./... && go test ./...` then `cd WatchtowerDesktop && swift build && swift test` — capture real exit codes (redirect to log files, check `$?`).
- [ ] **Step 2:** Invoke the **local-review** skill for the branch diff vs `main` (it runs the CI mirror + review panel + triage). Fix accepted findings, loop until convergence.
- [ ] **Step 3:** Push `feature/ideas-registry`, open PR to `main` (gh CLI, account per memory: vadimtrunov). PR body: summary, spec/plan links, contracts, test evidence. English.
- [ ] **Step 4:** Watch CI (`gh pr checks --watch`); drive to green (remember the dedupe-gate gotcha: "skipping" ≠ green — verify real runs).

---

## Self-review notes (spec coverage)

- Spec §5 → Task 1/2; §6.1 → Task 5; §6.2 → Task 6; §6.3/6.4 → Task 7; §6.5 → Task 3; §7 → Task 8/9; §5.4 → Task 4; §8 → Tasks 11–14; §9 → Tasks 9 (CLI) + 10 (MCP); §10 → Tasks 8 (tests) + 15 (doc); §11 → distributed per task.
- Deliberately NOT in the plan (spec non-goals): memory integration, backfill, decision→track conversion, digest-screen rendering of `digest_topics.ideas`.
