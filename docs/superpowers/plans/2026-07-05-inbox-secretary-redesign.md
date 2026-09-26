# Inbox Secretary Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Inbox decision core (trigger classifier → batch AI prioritize → pinned selector) with a two-stage smart secretary: a cheap-model triage scan over the *entire* new-message stream guided by a "secretary brief", plus strong-model per-item cards (why-it-matters / thread digest / draft reply), surfaced in a two-tier Desktop UI.

**Architecture:** The `internal/inbox/` package keeps its storage (`inbox_items`), lifecycle (auto-resolve, snooze, archive), learner/feedback, and watermark; the decision chain is replaced by `triage.go` (Layer 1, haiku/mini tier, batch) and `card.go` (Layer 2, sonnet/gpt tier, per item), both fed by `brief.go` (explicit profile + Watchtower auto-context + learned rules). `classifier.go`, `pinned_selector.go`, and `aiPrioritizeNewItems` are deleted. Desktop gets Action/Awareness tiers instead of Pinned/Feed, a secretary card UI, and a Profile editor.

**Tech Stack:** Go 1.25, goose migrations, modernc.org/sqlite, `digest.Generator` multi-provider AI (claude/codex CLI), SwiftUI + GRDB (macOS 14+).

**Spec:** `docs/superpowers/specs/2026-07-05-inbox-secretary-redesign-design.md`

## Global Constraints

- Work on a fresh branch `feature/inbox-secretary` cut from `main` (current `feature/task-ai-agent` has unrelated WIP).
- Behavior contracts live in `docs/inventory/inbox-pulse.md`. Owner approved this redesign (spec above): INBOX-01 and INBOX-07 are rewritten, INBOX-03 is closed, pinned-specific guards are replaced by tier analogs. INBOX-02, 04, 05, 06, 09 must not weaken. Any *other* guard change → stop and ask.
- Every new AI call must work on BOTH providers: model tier via `digest.WithSource(ctx, "<source>")` + entries in `internal/digest/models.go` AND `internal/codex/models.go` (never hardcode a model).
- Migrations: goose files `internal/db/migrations/0000N_<name>.sql` with `Up`/`Down`; mirror every change into `internal/db/schema.sql`; regenerate golden via `go test ./internal/db/ -run TestSchemaGolden -update`; never bump `CurrentSchemaFormat`.
- Verify commands must expose real exit codes: `go test ./... > /tmp/wt-test.log 2>&1; echo "exit=$?"` — never pipe through `tail`/`head`.
- Swift: `cd WatchtowerDesktop && swift build && swift test` (same exit-code rule), `make lint-swift`.
- All commit messages, code comments, and repo docs in English. UI copy in English ("Needs action", "FYI", "Preparing context…").
- Go tests: table-driven where natural; reuse `mockGenerator` from `internal/inbox/pipeline_test.go:24`. Swift tests: `TestDatabase.createDatabaseManager()` + `TestDatabase.cleanup(path:)`.

---

### Task 1: Migration 00009 — schema groundwork (new columns, `stream` trigger, secretary profile)

**Files:**
- Create: `internal/db/migrations/00009_inbox_secretary.sql`
- Modify: `internal/db/schema.sql` (inbox_items block at :443-483, workspace block at :5-13)
- Modify: `internal/db/models.go:529-554` (InboxItem struct)
- Modify: `internal/db/inbox.go:10-53` (column consts + scanners)
- Modify: `internal/db/workspace.go` (profile accessors)
- Modify: `internal/db/testdata/schema_v73.golden` (regenerated)
- Test: `internal/db/inbox_test.go`, `internal/db/workspace_test.go` (or nearest existing workspace test file)

**Interfaces:**
- Consumes: existing `inbox_items` schema, `workspace` single-row accessor pattern (`GetSearchLastDate`/`SetSearchLastDate` at `internal/db/workspace.go:42/:87`).
- Produces: `inbox_items` columns `why_matters`, `thread_digest`, `draft_reply`, `card_status` (`none`/`ready`/`failed`), `card_generated_at`; `trigger_type` accepts `'stream'`; `workspace.secretary_profile TEXT NOT NULL DEFAULT ''`; Go fields `InboxItem.WhyMatters, ThreadDigest, DraftReply, CardStatus, CardGeneratedAt string`; funcs `GetSecretaryProfile() (string, error)`, `SetSecretaryProfile(text string) error`. The `pinned` column is KEPT in this task (dropped in Task 8).

- [ ] **Step 1: Write failing tests**

In `internal/db/inbox_test.go` add:

```go
func TestInboxItemCardFieldsRoundTrip(t *testing.T) {
	d := newTestDB(t) // use this file's existing test-DB helper (see neighboring tests)
	id, err := d.CreateInboxItem(db.InboxItem{
		ChannelID: "C1", MessageTS: "100.1", SenderUserID: "U2",
		TriggerType: "stream", Snippet: "release blocked",
	})
	if err != nil {
		t.Fatalf("create with trigger_type=stream: %v", err)
	}
	it, err := d.GetInboxItem(id)
	if err != nil {
		t.Fatal(err)
	}
	if it.CardStatus != "none" {
		t.Fatalf("card_status default = %q, want none", it.CardStatus)
	}
	if it.WhyMatters != "" || it.ThreadDigest != "" || it.DraftReply != "" {
		t.Fatalf("card text fields should default empty")
	}
}
```

In the workspace test file add:

```go
func TestSecretaryProfileRoundTrip(t *testing.T) {
	d := newTestDB(t)
	if err := d.UpsertWorkspace(/* copy args from existing workspace tests */); err != nil {
		t.Fatal(err)
	}
	got, err := d.GetSecretaryProfile()
	if err != nil || got != "" {
		t.Fatalf("empty profile: got %q, err %v", got, err)
	}
	if err := d.SetSecretaryProfile("I own direction X; anything from the CEO is action"); err != nil {
		t.Fatal(err)
	}
	got, _ = d.GetSecretaryProfile()
	if got != "I own direction X; anything from the CEO is action" {
		t.Fatalf("round trip failed: %q", got)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestInboxItemCardFieldsRoundTrip|TestSecretaryProfileRoundTrip' > /tmp/wt-t1.log 2>&1; echo "exit=$?"`
Expected: exit=1 (CHECK constraint failure on `stream`, undefined fields/methods).

- [ ] **Step 3: Write the migration**

`internal/db/migrations/00009_inbox_secretary.sql`. Expanding `trigger_type` CHECK requires the table-recreation dance (model on `00002_target_due_inbox.sql`). New columns ride along:

```sql
-- +goose Up
PRAGMA defer_foreign_keys = ON;

CREATE TABLE inbox_items_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    pinned          INTEGER NOT NULL DEFAULT 0,
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_new (
    id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type,
    snippet, context, raw_text, permalink, status, priority, ai_reason,
    resolved_reason, snooze_until, waiting_user_ids, target_id, read_at,
    created_at, updated_at, item_class, pinned, archived_at, archive_reason
) SELECT
    id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type,
    snippet, context, raw_text, permalink, status, priority, ai_reason,
    resolved_reason, snooze_until, waiting_user_ids, target_id, read_at,
    created_at, updated_at, item_class, pinned, archived_at, archive_reason
FROM inbox_items;

DROP TABLE inbox_items;
ALTER TABLE inbox_items_new RENAME TO inbox_items;

-- Recreate ALL indexes: copy the eight CREATE INDEX statements VERBATIM
-- from internal/db/schema.sql:476-483 (idx_inbox_items_status, _priority,
-- _updated, _sender, _snooze, _class_status, _pinned, _archived).

ALTER TABLE workspace ADD COLUMN secretary_profile TEXT NOT NULL DEFAULT '';

-- +goose Down
PRAGMA defer_foreign_keys = ON;

-- Reverse dance: recreate the pre-00009 table shape (copy the CREATE TABLE
-- from the Up block of this file MINUS the five new columns and MINUS
-- 'stream' in the trigger_type CHECK), then:
-- INSERT INTO inbox_items_old (<24 old columns>)
--   SELECT <24 old columns> FROM inbox_items WHERE trigger_type != 'stream';
-- DROP TABLE inbox_items; ALTER TABLE inbox_items_old RENAME TO inbox_items;
-- recreate the same eight indexes.

ALTER TABLE workspace DROP COLUMN secretary_profile;
```

Write the Down block out in full (the comment above describes it; the actual file must contain real SQL — model it on `00002_target_due_inbox.sql:66-119`).

- [ ] **Step 4: Mirror into schema.sql**

In `internal/db/schema.sql`: add `'stream'` to the `trigger_type` CHECK list, append the five new columns to the `inbox_items` CREATE TABLE (same text as the migration), and add `secretary_profile TEXT NOT NULL DEFAULT ''` to the `workspace` table.

- [ ] **Step 5: Update Go model + scanners + accessors**

`internal/db/models.go` — append to `InboxItem`:

```go
	WhyMatters      string
	ThreadDigest    string
	DraftReply      string
	CardStatus      string // none|ready|failed
	CardGeneratedAt string
```

`internal/db/inbox.go` — append `why_matters, thread_digest, draft_reply, card_status, card_generated_at` to `inboxSelectCols`/`inboxItemColumns` (:10-18) and extend `scanInboxItem` (:21) with the five fields (`card_generated_at` scans via the same nullable-string handling used for `read_at`). `CreateInboxItem` (:55) is untouched — new columns take DB defaults.

`internal/db/workspace.go` — clone the `GetSearchLastDate`/`SetSearchLastDate` pair (:42/:87):

```go
// GetSecretaryProfile returns the user-written secretary brief text.
func (db *DB) GetSecretaryProfile() (string, error) {
	var s string
	err := db.QueryRow(`SELECT secretary_profile FROM workspace LIMIT 1`).Scan(&s)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return s, err
}

// SetSecretaryProfile stores the user-written secretary brief text.
func (db *DB) SetSecretaryProfile(text string) error {
	res, err := db.Exec(`UPDATE workspace SET secretary_profile = ? WHERE id = (SELECT id FROM workspace LIMIT 1)`, text)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no workspace row exists")
	}
	return nil
}
```

(Match the exact error-wrapping style of the neighboring setters.)

- [ ] **Step 6: Regenerate golden + run the migration test battery**

Run: `go test ./internal/db/ -run TestSchemaGolden -update > /tmp/wt-t1.log 2>&1; echo "exit=$?"`
Then: `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestInboxItemCardFieldsRoundTrip|TestSecretaryProfileRoundTrip' > /tmp/wt-t1.log 2>&1; echo "exit=$?"`
Expected: exit=0.

- [ ] **Step 7: Full package test + commit**

Run: `go test ./internal/db/ > /tmp/wt-t1.log 2>&1; echo "exit=$?"` → exit=0.

```bash
git add internal/db/ && git commit -m "feat(db): inbox secretary schema — card columns, stream trigger, secretary profile"
```

---

### Task 2: Register `inbox.triage` + `inbox.card` prompts and model routing

**Files:**
- Modify: `internal/prompts/store.go:14-42` (ID consts)
- Modify: `internal/prompts/defaults.go` (template consts + `Defaults`/`AllIDs`/`DefaultVersions`/`Descriptions` maps)
- Modify: `internal/digest/models.go:10-16`, `internal/codex/models.go:12-19`
- Test: `internal/digest/models_test.go`, `internal/codex/models_test.go`, `internal/prompts/` (existing seed/defaults test if present)

**Interfaces:**
- Produces: `prompts.InboxTriage = "inbox.triage"`, `prompts.InboxCard = "inbox.card"`. Triage template has **3 `%s` slots**: language directive, secretary brief, candidates block. Card template has **3 `%s` slots**: language directive, secretary brief, item+conversation block. Source `"inbox.triage"` routes to Haiku / `gpt-5.4-mini`; `"inbox.card"` intentionally NOT in the switches (defaults to Sonnet / `gpt-5.4`).
- Note: `inbox.prioritize` stays registered until Task 8 (the old pipeline still runs until Task 7).

- [ ] **Step 1: Write failing routing tests**

Add to the existing table in `internal/digest/models_test.go::TestModelForSource`: `{"inbox.triage", ModelHaiku}` and `{"inbox.card", ModelSonnet}`. Mirror in `internal/codex/models_test.go::TestModelForSource`: `{"inbox.triage", ModelLightweight}`, `{"inbox.card", ModelDefault}`.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/digest/ ./internal/codex/ -run TestModelForSource > /tmp/wt-t2.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement routing + prompt registration**

Add `case "inbox.triage":` to the cheap branch of both `ModelForSource` switches.

`internal/prompts/store.go`: add

```go
	InboxTriage = "inbox.triage"
	InboxCard   = "inbox.card"
```

`internal/prompts/defaults.go`: add both to `Defaults`, `AllIDs`, `DefaultVersions` (value `1`), `Descriptions` ("Inbox: triage scan of new activity" / "Inbox: secretary card for a surfaced item"), plus the template consts:

```go
const defaultInboxTriage = `%s

You are the user's chief-of-staff secretary. You read EVERYTHING that happened
in their Slack/Jira/Calendar since the last scan and decide what deserves their
attention. Be ruthless: most messages are noise for this specific user.

%s

Classify every candidate below into exactly one tier:
- "action"    — the user personally must respond or act. Missing it has consequences.
- "awareness" — the user should know (a decision, an escalation, movement on their
                projects/people), but nobody is waiting on them.
- "ignore"    — noise for this user. Bot chatter, FYI they don't care about,
                threads that don't touch their scope.

Rules:
- Judge against the brief above: the user's own words outrank everything else.
- Respect Mutes/Boosts. A muted source needs an extraordinary reason to surface.
- Never invent candidates. Return a verdict for every key exactly once.
- Candidates marked [TRIGGER] were detected as direct signals (mention/DM/
  assignment). You may demote them to "awareness" but NEVER to "ignore".
- priority: how urgent within its tier ("high"|"medium"|"low").
- reason: ONE short sentence, in the user's language, explaining the verdict
  from the user's point of view.

%s

Return ONLY a JSON object (no markdown fences):
{"verdicts":[{"key":"item:12","tier":"action","priority":"high","reason":"..."}]}`

const defaultInboxCard = `%s

You are the user's chief-of-staff secretary preparing a briefing card for one
inbox item they will act on.

%s

Using the item and conversation below, produce:
- why_matters: 1-2 sentences — why this needs the user specifically, judged
  against the brief (who is asking, which of the user's projects/people it
  touches, what happens if ignored).
- thread_digest: 3-5 sentences summarizing the whole conversation so the user
  does not have to read it. Lead with the current state, not the history.
- draft_reply: a ready-to-send reply in the user's voice: direct, short, no
  corporate fluff. Match the language of the conversation. If the right action
  is not a reply (e.g. RSVP, close a ticket), say what to do in one line instead.

%s

Return ONLY a JSON object (no markdown fences):
{"why_matters":"...","thread_digest":"...","draft_reply":"..."}`
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/digest/ ./internal/codex/ ./internal/prompts/ > /tmp/wt-t2.log 2>&1; echo "exit=$?"` → exit=0. (If a prompts test asserts the exact `AllIDs` count/order, update it.)

- [ ] **Step 5: Commit**

```bash
git add internal/prompts/ internal/digest/models*.go internal/codex/models*.go
git commit -m "feat(prompts): register inbox.triage (cheap tier) and inbox.card (strong tier)"
```

---

### Task 3: Secretary brief builder (`internal/inbox/brief.go`)

**Files:**
- Create: `internal/inbox/brief.go`
- Test: `internal/inbox/brief_test.go`

**Interfaces:**
- Consumes: `db.GetSecretaryProfile()` (Task 1), `db.GetUserProfile(slackUserID) (*db.UserProfile, error)` (`internal/db/profile.go:11` — fields Role, Team), `db.GetAllActiveTracks() ([]db.Track, error)` (`internal/db/tracks.go:172` — fields Text, Priority, BallOn, Ownership), `db.GetJiraIssuesForUser(slackID, statusCategory string) ([]db.JiraIssue, error)` (`internal/db/jira.go:903` — pass `""`, filter `StatusCategory != "Done"` in Go), `db.GetCalendarEventsForDate(date string) ([]db.CalendarEvent, error)` (`internal/db/calendar.go:158` — fields Title, StartTime).
- Produces: `buildSecretaryBrief(database *db.DB, currentUserID string, now time.Time) string` — a `=== SECRETARY BRIEF ===` block. Every data source is best-effort: errors are swallowed (the section is omitted), the function never fails. Learned rules are NOT included here — they stay per-candidate-scoped via `buildUserPreferencesBlock` (`user_preferences.go:16`), appended by callers.

- [ ] **Step 1: Write failing tests**

`internal/inbox/brief_test.go` (use the package's existing test-DB helper from `testhelpers_test.go`):

```go
func TestBuildSecretaryBrief_AllSections(t *testing.T) {
	d := newTestDB(t) // this package's existing helper
	seedWorkspace(t, d)
	if err := d.SetSecretaryProfile("I run direction X. CEO pings are always action."); err != nil {
		t.Fatal(err)
	}
	// seed one active track, one open jira issue assigned to U1, one calendar
	// event for today — reuse insert helpers/fixtures from neighboring tests
	// (tracks: see internal/db/tracks_test.go fixtures; jira: jira_test.go;
	// calendar: calendar_test.go). Copy the minimal insert calls here.
	got := buildSecretaryBrief(d, "U1", time.Date(2026, 7, 5, 10, 0, 0, 0, time.UTC))
	for _, want := range []string{
		"=== SECRETARY BRIEF ===",
		"I run direction X. CEO pings are always action.",
		"ACTIVE TRACKS", "MY OPEN JIRA", "TODAY'S CALENDAR",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("brief missing %q\n---\n%s", want, got)
		}
	}
}

func TestBuildSecretaryBrief_EmptySourcesStillUsable(t *testing.T) {
	d := newTestDB(t)
	seedWorkspace(t, d)
	got := buildSecretaryBrief(d, "U1", time.Now())
	if !strings.Contains(got, "=== SECRETARY BRIEF ===") {
		t.Fatalf("brief must always carry its header, got: %q", got)
	}
	if strings.Contains(got, "ACTIVE TRACKS") {
		t.Errorf("empty track list must omit the section")
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/inbox/ -run TestBuildSecretaryBrief > /tmp/wt-t3.log 2>&1; echo "exit=$?"` → exit=1 (undefined `buildSecretaryBrief`).

- [ ] **Step 3: Implement**

`internal/inbox/brief.go`:

```go
package inbox

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

const (
	maxBriefTracks = 15
	maxBriefJira   = 10
	maxBriefEvents = 10
)

// buildSecretaryBrief assembles the user-knowledge block injected into both
// inbox AI prompts. Every source is best-effort: a failing or empty source
// just omits its section.
func buildSecretaryBrief(database *db.DB, currentUserID string, now time.Time) string {
	var b strings.Builder
	b.WriteString("=== SECRETARY BRIEF ===\n")

	if profile, err := database.GetSecretaryProfile(); err == nil && profile != "" {
		b.WriteString("USER'S OWN INSTRUCTIONS (highest authority):\n")
		b.WriteString(profile + "\n\n")
	}
	if up, err := database.GetUserProfile(currentUserID); err == nil && up != nil && up.Role != "" {
		fmt.Fprintf(&b, "ROLE: %s", up.Role)
		if up.Team != "" {
			fmt.Fprintf(&b, " (team: %s)", up.Team)
		}
		b.WriteString("\n\n")
	}
	if tracks, err := database.GetAllActiveTracks(); err == nil && len(tracks) > 0 {
		b.WriteString("ACTIVE TRACKS (the user's ongoing storylines):\n")
		for i, tr := range tracks {
			if i >= maxBriefTracks {
				break
			}
			fmt.Fprintf(&b, "- [%s] %s (ball on: %s)\n", tr.Priority, tr.Text, tr.BallOn)
		}
		b.WriteString("\n")
	}
	if issues, err := database.GetJiraIssuesForUser(currentUserID, ""); err == nil {
		var open []db.JiraIssue
		for _, is := range issues {
			if is.StatusCategory != "Done" {
				open = append(open, is)
			}
		}
		if len(open) > 0 {
			b.WriteString("MY OPEN JIRA:\n")
			for i, is := range open {
				if i >= maxBriefJira {
					break
				}
				fmt.Fprintf(&b, "- %s %s (%s)\n", is.Key, is.Summary, is.Status)
			}
			b.WriteString("\n")
		}
	}
	if events, err := database.GetCalendarEventsForDate(now.Format("2006-01-02")); err == nil && len(events) > 0 {
		b.WriteString("TODAY'S CALENDAR:\n")
		for i, ev := range events {
			if i >= maxBriefEvents {
				break
			}
			fmt.Fprintf(&b, "- %s %s\n", ev.StartTime, ev.Title)
		}
		b.WriteString("\n")
	}
	return b.String()
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/inbox/ -run TestBuildSecretaryBrief > /tmp/wt-t3.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit**

```bash
git add internal/inbox/brief.go internal/inbox/brief_test.go
git commit -m "feat(inbox): secretary brief builder (profile + tracks + jira + calendar)"
```

---

### Task 4: DB layer — stream candidates and card queries

**Files:**
- Modify: `internal/db/inbox.go`
- Test: `internal/db/inbox_test.go`

**Interfaces:**
- Consumes: `messages` table (`schema.sql:54-67`, `ts_unix` generated column), `channels.type` (`'public'|'private'|'dm'|'group_dm'`), `InboxCandidate` (`models.go:557-566`).
- Produces:
  - `ListStreamCandidatesSince(currentUserID string, sinceTS float64, limit int) ([]InboxCandidate, error)` — ordered `ts_unix ASC` (oldest first, so a capped scan can advance the watermark to the last processed message). Excludes: deleted, subtyped (joins/edits), empty/self author, `dm` channels (DMs are trigger-detected), messages already in `inbox_items`, and messages whose thread already has a pending item.
  - `SetInboxCard(id int, whyMatters, threadDigest, draftReply string) error` — sets the three texts, `card_status='ready'`, `card_generated_at=now`, `updated_at=now`.
  - `MarkInboxCardFailed(id int) error` — `card_status='failed'`, `updated_at=now`.
  - `ListItemsNeedingCards(awarenessLimit int) ([]InboxItem, error)` — pending, unarchived, `card_status IN ('none','failed')`: ALL `item_class='actionable'` plus at most `awarenessLimit` newest `item_class='ambient'`.

- [ ] **Step 1: Write failing tests**

Add to `internal/db/inbox_test.go` (reuse this file's message/channel insert fixtures):

```go
func TestListStreamCandidatesSince(t *testing.T) {
	d := newTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertChannel(t, d, "D1", "dm")
	insertMessage(t, d, "C1", "100.1", "U2", "release blocked on infra") // candidate
	insertMessage(t, d, "C1", "100.2", "U1", "my own message")           // self → excluded
	insertMessage(t, d, "D1", "100.3", "U2", "dm text")                  // dm → excluded
	insertMessage(t, d, "C1", "99.0", "U2", "too old")                   // before watermark

	got, err := d.ListStreamCandidatesSince("U1", 99.5, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].MessageTS != "100.1" {
		t.Fatalf("want exactly the C1/100.1 candidate, got %+v", got)
	}
	if got[0].TriggerType != "stream" {
		t.Fatalf("trigger type = %q, want stream", got[0].TriggerType)
	}
}

func TestListStreamCandidatesSince_SkipsAlreadyInboxed(t *testing.T) {
	d := newTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "hello")
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "100.1", SenderUserID: "U2", TriggerType: "mention"})
	got, _ := d.ListStreamCandidatesSince("U1", 0, 100)
	if len(got) != 0 {
		t.Fatalf("already-inboxed message must not be a candidate, got %+v", got)
	}
}

func TestListStreamCandidatesSince_CapAndOrder(t *testing.T) {
	d := newTestDB(t)
	insertChannel(t, d, "C1", "public")
	for i := 1; i <= 5; i++ {
		insertMessage(t, d, "C1", fmt.Sprintf("10%d.0", i), "U2", "msg")
	}
	got, _ := d.ListStreamCandidatesSince("U1", 0, 3)
	if len(got) != 3 || got[0].MessageTS != "101.0" || got[2].MessageTS != "103.0" {
		t.Fatalf("want oldest-first capped at 3, got %+v", got)
	}
}

func TestInboxCardLifecycle(t *testing.T) {
	d := newTestDB(t)
	actionID := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention"}) // actionable by default
	ambient1 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream"})
	ambient2 := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "3.1", SenderUserID: "U2", TriggerType: "stream"})
	for _, id := range []int64{ambient1, ambient2} {
		if err := d.SetInboxItemClass(id, "ambient"); err != nil {
			t.Fatal(err)
		}
	}

	need, err := d.ListItemsNeedingCards(1)
	if err != nil {
		t.Fatal(err)
	}
	if len(need) != 2 { // 1 actionable + 1 capped ambient
		t.Fatalf("want 2 items needing cards, got %d", len(need))
	}

	if err := d.SetInboxCard(int(actionID), "why", "digest", "draft"); err != nil {
		t.Fatal(err)
	}
	it, _ := d.GetInboxItem(actionID)
	if it.CardStatus != "ready" || it.WhyMatters != "why" || it.CardGeneratedAt == "" {
		t.Fatalf("card not persisted: %+v", it)
	}

	if err := d.MarkInboxCardFailed(int(ambient1)); err != nil {
		t.Fatal(err)
	}
	need, _ = d.ListItemsNeedingCards(5)
	// actionID is ready now; ambient1 failed (retryable) + ambient2 none
	if len(need) != 2 {
		t.Fatalf("failed card must stay retryable, got %d items", len(need))
	}
}
```

(If `insertChannel`/`insertMessage`/`mustCreateInboxItem` helpers don't exist under these names, use/extend this file's actual fixture helpers — check neighboring detection tests around `FindPendingMentions`.)

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db/ -run 'TestListStreamCandidates|TestInboxCardLifecycle' > /tmp/wt-t4.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement**

Append to `internal/db/inbox.go`:

```go
// ListStreamCandidatesSince returns non-trigger messages newer than sinceTS
// for the full-stream triage scan, oldest first, capped at limit.
func (db *DB) ListStreamCandidatesSince(currentUserID string, sinceTS float64, limit int) ([]InboxCandidate, error) {
	rows, err := db.Query(`
		SELECT m.channel_id, m.ts, COALESCE(m.thread_ts,''), m.user_id, m.text, COALESCE(m.permalink,''), m.ts_unix
		FROM messages m
		JOIN channels c ON c.id = m.channel_id
		WHERE m.ts_unix > ?
		  AND m.is_deleted = 0
		  AND COALESCE(m.subtype,'') = ''
		  AND m.user_id != ''
		  AND m.user_id != ?
		  AND c.type != 'dm'
		  AND NOT EXISTS (
		      SELECT 1 FROM inbox_items i
		      WHERE i.channel_id = m.channel_id AND i.message_ts = m.ts)
		  AND NOT EXISTS (
		      SELECT 1 FROM inbox_items i2
		      WHERE i2.channel_id = m.channel_id
		        AND i2.thread_ts != '' AND i2.thread_ts = COALESCE(m.thread_ts,'')
		        AND i2.status = 'pending')
		ORDER BY m.ts_unix ASC
		LIMIT ?`, sinceTS, currentUserID, limit)
	// scan into InboxCandidate{..., TriggerType: "stream"} — follow the
	// row-scanning shape of FindPendingMentions (inbox.go:407).
}

// SetInboxCard stores a generated secretary card on an item.
func (db *DB) SetInboxCard(id int, whyMatters, threadDigest, draftReply string) error {
	_, err := db.Exec(`UPDATE inbox_items
		SET why_matters = ?, thread_digest = ?, draft_reply = ?,
		    card_status = 'ready',
		    card_generated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, whyMatters, threadDigest, draftReply, id)
	return err
}

// MarkInboxCardFailed flags a card generation failure; the item stays
// eligible for retry on the next cycle.
func (db *DB) MarkInboxCardFailed(id int) error {
	_, err := db.Exec(`UPDATE inbox_items
		SET card_status = 'failed',
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, id)
	return err
}

// ListItemsNeedingCards returns pending items without a ready card: all
// actionable ones plus at most awarenessLimit newest ambient ones.
func (db *DB) ListItemsNeedingCards(awarenessLimit int) ([]InboxItem, error) {
	rows, err := db.Query(`
		SELECT `+inboxSelectCols+` FROM inbox_items
		WHERE status = 'pending' AND archived_at IS NULL
		  AND card_status IN ('none','failed')
		  AND (item_class = 'actionable'
		       OR id IN (SELECT id FROM inbox_items
		                 WHERE status='pending' AND archived_at IS NULL
		                   AND card_status IN ('none','failed') AND item_class='ambient'
		                 ORDER BY created_at DESC LIMIT ?))
		ORDER BY item_class, created_at DESC`, awarenessLimit)
	// scan with scanInboxItems (inbox.go:38)
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/db/ > /tmp/wt-t4.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit**

```bash
git add internal/db/inbox.go internal/db/inbox_test.go
git commit -m "feat(db): stream-candidate scan and secretary card queries"
```

---

### Task 5: Triage stage (`internal/inbox/triage.go`)

**Files:**
- Create: `internal/inbox/triage.go`
- Modify: `internal/config/config.go:52-57,203-205`, `internal/config/defaults.go:23-25` (both new config fields land here — Task 6 and 7 consume them)
- Test: `internal/inbox/triage_test.go`

**Interfaces:**
- Consumes: `p.generator digest.Generator` (`Generate(ctx, systemPrompt, userMessage, sessionID) (string, *digest.Usage, string, error)`), `prompts.InboxTriage` + `p.getPrompt` (`pipeline.go:824`), `prompts.Directive(lang)`, `buildSecretaryBrief` (Task 3), `buildUserPreferencesBlock` (`user_preferences.go:16`), `db.ListStreamCandidatesSince` (Task 4), `db.CreateInboxItem`, `db.BulkUpdateInboxPriorities` (`inbox.go:309`), `db.SetInboxItemClass` (`inbox.go:652`), `db.ListAllLearnedRules`.
- Produces:

```go
type triageVerdict struct {
	Key      string `json:"key"`      // "item:<id>" or "msg:<channel_id>:<ts>"
	Tier     string `json:"tier"`     // action|awareness|ignore
	Priority string `json:"priority"` // high|medium|low
	Reason   string `json:"reason"`
}
type triageOutcome struct {
	Created        int     // stream items created
	MaxProcessedTS float64 // highest ts_unix of a triaged stream candidate (0 if none)
	Capped         bool    // stream scan hit the per-cycle cap
}
func (p *Pipeline) runTriage(ctx context.Context, currentUserID string, newItems []db.InboxItem) (triageOutcome, error)
```

  Behavior contract: trigger items (`newItems`, i.e. every trigger_type except `stream`) may be demoted `actionable→ambient` but a verdict of `ignore` on them is coerced to `awareness` (INBOX-01: AI only downgrades). Hard-muted candidates (`source_mute` rule with `Weight <= -0.8` matching `sender:<id>` or `channel:<id>`) are dropped BEFORE the AI sees them (stream) / skipped from demotion protection (items keep flowing — mute affects stream candidates only, existing trigger items still get priorities). Chunking: `maxTriagePerCall = 150` candidates per Generate call, chunks processed oldest-first; the FIRST failing chunk aborts triage and returns the outcome accumulated so far plus the error (so the caller freezes the watermark at the last fully-triaged point).

- [ ] **Step 1: Write failing tests**

`internal/inbox/triage_test.go` (reuse `mockGenerator` from `pipeline_test.go:24-30`; make a small sequenced variant here if per-call responses are needed):

```go
// seqGenerator returns queued responses in order; an entry of "" simulates an AI error.
type seqGenerator struct {
	responses []string
	calls     int
	prompts   []string
}

func (g *seqGenerator) Generate(_ context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.prompts = append(g.prompts, system+"\n"+user)
	if g.calls >= len(g.responses) {
		return "", nil, "", fmt.Errorf("unexpected extra call")
	}
	r := g.responses[g.calls]
	g.calls++
	if r == "" {
		return "", nil, "", fmt.Errorf("ai down")
	}
	return r, &digest.Usage{}, "", nil
}

func TestTriage_StreamCandidateBecomesItem(t *testing.T) {
	d, p, gen := newTriagePipeline(t) // helper: test DB + Pipeline with seqGenerator
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "prod is on fire, need direction owner")
	gen.responses = []string{`{"verdicts":[{"key":"msg:C1:100.1","tier":"action","priority":"high","reason":"prod incident in your area"}]}`}

	out, err := p.runTriage(context.Background(), "U1", nil)
	if err != nil || out.Created != 1 {
		t.Fatalf("created=%d err=%v", out.Created, err)
	}
	it, _ := d.GetInboxItemByMessage("C1", "100.1")
	if it == nil || it.TriggerType != "stream" || it.ItemClass != "actionable" || it.Priority != "high" {
		t.Fatalf("stream item wrong: %+v", it)
	}
	if it.AIReason != "prod incident in your area" {
		t.Fatalf("ai_reason = %q", it.AIReason)
	}
}

func TestTriage_IgnoreVerdictCreatesNothing(t *testing.T) { /* same shape; tier=ignore; assert no item */ }

func TestInbox01_TriggerNeverIgnored(t *testing.T) {
	// A mention item sent to triage with verdict tier=ignore must remain
	// pending with item_class demoted at most to 'ambient'.
	d, p, gen := newTriagePipeline(t)
	id := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention"})
	gen.responses = []string{fmt.Sprintf(`{"verdicts":[{"key":"item:%d","tier":"ignore","priority":"low","reason":"bot noise"}]}`, id)}
	items, _ := d.GetInboxItems(db.InboxFilter{Status: "pending"})
	if _, err := p.runTriage(context.Background(), "U1", items); err != nil {
		t.Fatal(err)
	}
	it, _ := d.GetInboxItem(id)
	if it.Status != "pending" || it.ItemClass != "ambient" {
		t.Fatalf("trigger item must be demoted, never dropped: %+v", it)
	}
}

func TestInbox01_TriageNeverUpgrades(t *testing.T) {
	// An item already 'ambient' getting tier=action keeps class 'ambient'
	// (priority/reason still update).
}

func TestTriage_HardMutedStreamCandidateSkipped(t *testing.T) {
	// UpsertLearnedRule source_mute channel:C9 weight -1.0 → message in C9
	// never reaches the generator (assert gen.calls == 0 when it is the only candidate).
}

func TestTriage_ChunkingAndPartialFailure(t *testing.T) {
	// 2 chunks (insert maxTriagePerCall+1 stream messages, cheap texts).
	// Chunk 1 OK (all "ignore"), chunk 2 errors ("").
	// Expect: err != nil, out.MaxProcessedTS == ts of last chunk-1 message.
}

func TestInbox07_InvalidJSONLeavesStateUntouched(t *testing.T) {
	// Response "not json" → error returned, no items created/modified.
}
```

Write `newTriagePipeline` in this file: create the package test DB, seed workspace + current user, build `New(d, testConfig(), gen, logger)` following `pipeline_test.go` setup.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/inbox/ -run 'TestTriage|TestInbox01_Trigger|TestInbox01_TriageNeverUpgrades|TestInbox07_InvalidJSON' > /tmp/wt-t5.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement `triage.go`**

```go
package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

const maxTriagePerCall = 150

type triageVerdict struct {
	Key      string `json:"key"`
	Tier     string `json:"tier"`
	Priority string `json:"priority"`
	Reason   string `json:"reason"`
}

type triageResult struct {
	Verdicts []triageVerdict `json:"verdicts"`
}

type triageOutcome struct {
	Created        int
	MaxProcessedTS float64
	Capped         bool
}

// triageCandidate is one line the AI judges: either an existing trigger item
// or a raw stream message.
type triageCandidate struct {
	key    string
	line   string  // formatted prompt line
	item   *db.InboxItem      // set for trigger items
	stream *db.InboxCandidate // set for stream messages
}

func (p *Pipeline) runTriage(ctx context.Context, currentUserID string, newItems []db.InboxItem) (triageOutcome, error) {
	var out triageOutcome

	maxStream := p.cfg.Inbox.MaxTriageMessages
	lastTS, _ := p.db.GetInboxLastProcessedTS()
	streamCands, err := p.db.ListStreamCandidatesSince(currentUserID, lastTS, maxStream)
	if err != nil {
		return out, fmt.Errorf("listing stream candidates: %w", err)
	}
	out.Capped = len(streamCands) == maxStream

	mutes := hardMuteScopes(p.db)
	cands := make([]triageCandidate, 0, len(newItems)+len(streamCands))
	for i := range newItems {
		it := &newItems[i]
		cands = append(cands, triageCandidate{
			key:  fmt.Sprintf("item:%d", it.ID),
			line: fmt.Sprintf("[TRIGGER] key=item:%d type=%s from=%s channel=%s :: %s", it.ID, it.TriggerType, it.SenderUserID, it.ChannelID, it.Snippet),
			item: it,
		})
	}
	for i := range streamCands {
		c := &streamCands[i]
		if mutes["sender:"+c.SenderUserID] || mutes["channel:"+c.ChannelID] {
			out.MaxProcessedTS = c.TSUnix // muted = processed
			continue
		}
		cands = append(cands, triageCandidate{
			key:    fmt.Sprintf("msg:%s:%s", c.ChannelID, c.MessageTS),
			line:   fmt.Sprintf("key=msg:%s:%s from=%s channel=%s :: %s", c.ChannelID, c.MessageTS, c.SenderUserID, c.ChannelID, cleanSnippet(c.Text)),
			stream: c,
		})
	}
	if len(cands) == 0 {
		return out, nil
	}

	brief := buildSecretaryBrief(p.db, currentUserID, time.Now())
	tmpl, _ := p.getPrompt(prompts.InboxTriage)

	for start := 0; start < len(cands); start += maxTriagePerCall {
		end := min(start+maxTriagePerCall, len(cands))
		chunk := cands[start:end]
		if err := p.triageChunk(ctx, brief, tmpl, chunk, &out); err != nil {
			return out, err // caller freezes/partially advances the watermark
		}
	}
	return out, nil
}

func (p *Pipeline) triageChunk(ctx context.Context, brief, tmpl string, chunk []triageCandidate, out *triageOutcome) error {
	var block strings.Builder
	block.WriteString("=== CANDIDATES ===\n")
	byKey := make(map[string]*triageCandidate, len(chunk))
	for i := range chunk {
		block.WriteString(chunk[i].line + "\n")
		byKey[chunk[i].key] = &chunk[i]
	}
	// scoped learned rules (mutes/boosts) for the items in this chunk
	var chunkItems []db.InboxItem
	for _, c := range chunk {
		if c.item != nil {
			chunkItems = append(chunkItems, *c.item)
		}
	}
	if prefs, err := buildUserPreferencesBlock(p.db, chunkItems); err == nil && prefs != "" {
		block.WriteString("\n" + prefs)
	}

	system := fmt.Sprintf(tmpl, prompts.Directive(p.cfg.Digest.Language), brief, block.String())
	raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "inbox.triage"), system, "Triage these candidates.", "")
	if err != nil {
		return fmt.Errorf("triage AI call: %w", err)
	}
	p.accumulateUsage(usage) // extract the existing usage-accumulation lines (pipeline.go:731-737) into this helper

	var res triageResult
	if err := json.Unmarshal([]byte(prompts.ExtractJSONObject(raw)), &res); err != nil {
		return fmt.Errorf("triage response parse: %w", err)
	}

	prioUpdates := make(map[int]struct{ Priority, AIReason string })
	for _, v := range res.Verdicts {
		c, ok := byKey[v.Key]
		if !ok {
			continue // hallucinated key
		}
		prio := v.Priority
		if prio != "high" && prio != "medium" && prio != "low" {
			prio = "medium"
		}
		switch {
		case c.item != nil:
			tier := v.Tier
			if tier == "ignore" { // INBOX-01: triggers can be demoted, never dropped
				tier = "awareness"
			}
			prioUpdates[c.item.ID] = struct{ Priority, AIReason string }{prio, v.Reason}
			if tier == "awareness" && c.item.ItemClass == "actionable" {
				_ = p.db.SetInboxItemClass(int64(c.item.ID), "ambient")
			}
			// tier == "action" on an ambient item: no upgrade (INBOX-01)
		case c.stream != nil:
			if c.stream.TSUnix > out.MaxProcessedTS {
				out.MaxProcessedTS = c.stream.TSUnix
			}
			if v.Tier != "action" && v.Tier != "awareness" {
				continue // ignore → nothing persisted
			}
			class := "actionable"
			if v.Tier == "awareness" {
				class = "ambient"
			}
			if _, err := p.db.CreateInboxItem(db.InboxItem{
				ChannelID: c.stream.ChannelID, MessageTS: c.stream.MessageTS,
				ThreadTS: c.stream.ThreadTS, SenderUserID: c.stream.SenderUserID,
				TriggerType: "stream", Snippet: cleanSnippet(c.stream.Text),
				RawText: c.stream.Text, Permalink: c.stream.Permalink,
				Priority: prio, AIReason: v.Reason, ItemClass: class,
			}); err == nil {
				out.Created++
			}
		}
	}
	// stream candidates the AI ignored are still processed
	for _, c := range chunk {
		if c.stream != nil && c.stream.TSUnix > out.MaxProcessedTS {
			out.MaxProcessedTS = c.stream.TSUnix
		}
	}
	if len(prioUpdates) > 0 {
		if err := p.db.BulkUpdateInboxPriorities(prioUpdates); err != nil {
			return fmt.Errorf("applying triage priorities: %w", err)
		}
	}
	return nil
}

// hardMuteScopes returns scope keys with a source_mute weight <= -0.8.
// (Moved from pinned_selector.go's loadMuteScopes; that file dies in Task 7.)
func hardMuteScopes(database *db.DB) map[string]bool {
	rules, err := database.ListAllLearnedRules()
	if err != nil {
		return nil
	}
	m := make(map[string]bool)
	for _, r := range rules {
		if r.RuleType == "source_mute" && r.Weight <= -0.8 {
			m[r.ScopeKey] = true
		}
	}
	return m
}
```

Check `CreateInboxItem` (`internal/db/inbox.go:55`): it currently forces `ItemClass=actionable` when empty — confirm it respects an explicitly passed `ItemClass: "ambient"`; if it doesn't, fix it there in this task. Also confirm the exact `BulkUpdateInboxPriorities` map value type at `inbox.go:309` and match it. Add the `accumulateUsage(*digest.Usage)` helper to `pipeline.go` and refactor `aiPrioritizeNewItems` to use it (keeps one accounting path until Task 7 deletes it).

Config (used here and by Tasks 6-7): add to `InboxConfig` (`internal/config/config.go:52-57`) fields `MaxTriageMessages int` (`mapstructure:"max_triage_messages"`) and `MaxAwarenessCards int` (`mapstructure:"max_awareness_cards"` — match the tag style of the neighboring fields); constants `DefaultInboxMaxTriageMessages = 600`, `DefaultInboxMaxAwarenessCards = 3` in `internal/config/defaults.go:23-25`; viper registration next to `inbox.max_items_per_run` (`config.go:203-205`). The `newTriagePipeline` test helper must set both fields on its config.

- [ ] **Step 4: Run tests**

Run: `go test ./internal/inbox/ > /tmp/wt-t5.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit**

```bash
git add internal/inbox/triage.go internal/inbox/triage_test.go internal/inbox/pipeline.go
git commit -m "feat(inbox): triage stage — full-stream scan with secretary brief"
```

---

### Task 6: Card stage (`internal/inbox/card.go`)

**Files:**
- Create: `internal/inbox/card.go`
- Test: `internal/inbox/card_test.go`

**Interfaces:**
- Consumes: `db.ListItemsNeedingCards`, `db.SetInboxCard`, `db.MarkInboxCardFailed` (Task 4), `p.loadContext(channelID, messageTS, threadTS) string` (`pipeline.go:601` — existing conversation-context builder), `prompts.InboxCard`, `buildSecretaryBrief`.
- Produces: `func (p *Pipeline) runCards(ctx context.Context, currentUserID string) (generated int, err error)`. Per-item failures are non-fatal (`MarkInboxCardFailed` + continue); the returned error is non-nil only if listing items fails. Card failures never block the watermark.

```go
type cardResult struct {
	WhyMatters   string `json:"why_matters"`
	ThreadDigest string `json:"thread_digest"`
	DraftReply   string `json:"draft_reply"`
}
```

- [ ] **Step 1: Write failing tests**

`internal/inbox/card_test.go`:

```go
func TestRunCards_GeneratesAndPersists(t *testing.T) {
	d, p, gen := newTriagePipeline(t)
	id := mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention", Snippet: "need your sign-off"})
	gen.responses = []string{`{"why_matters":"CEO is waiting","thread_digest":"Thread about the Q3 launch sign-off.","draft_reply":"Approved, ship it."}`}

	n, err := p.runCards(context.Background(), "U1")
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	it, _ := d.GetInboxItem(id)
	if it.CardStatus != "ready" || it.DraftReply != "Approved, ship it." {
		t.Fatalf("card not persisted: %+v", it)
	}
}

func TestInbox07_CardFailureMarksFailedAndContinues(t *testing.T) {
	// Two items; first Generate errors, second succeeds.
	// Expect: item1 card_status=failed, item2 ready, err == nil, n == 1.
}

func TestRunCards_InvalidJSONMarksFailed(t *testing.T) {
	// Response "oops" → card_status=failed, snippet/status untouched.
}

func TestRunCards_AwarenessCapRespected(t *testing.T) {
	// 3 ambient items, cfg.Inbox.MaxAwarenessCards=1 → exactly 1 Generate call.
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/inbox/ -run 'TestRunCards|TestInbox07_Card' > /tmp/wt-t6.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement `card.go`**

```go
package inbox

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

type cardResult struct {
	WhyMatters   string `json:"why_matters"`
	ThreadDigest string `json:"thread_digest"`
	DraftReply   string `json:"draft_reply"`
}

// runCards generates secretary cards (why-it-matters / thread digest / draft
// reply) for items surfaced by triage. Per-item failures are recorded and
// retried next cycle; they never fail the pipeline (INBOX-07).
func (p *Pipeline) runCards(ctx context.Context, currentUserID string) (int, error) {
	items, err := p.db.ListItemsNeedingCards(p.cfg.Inbox.MaxAwarenessCards)
	if err != nil {
		return 0, fmt.Errorf("listing items needing cards: %w", err)
	}
	if len(items) == 0 || p.generator == nil {
		return 0, nil
	}

	brief := buildSecretaryBrief(p.db, currentUserID, time.Now())
	tmpl, _ := p.getPrompt(prompts.InboxCard)

	generated := 0
	for _, it := range items {
		itemBlock := fmt.Sprintf("=== ITEM ===\ntype=%s from=%s channel=%s\nsnippet: %s\n\n=== CONVERSATION ===\n%s",
			it.TriggerType, it.SenderUserID, it.ChannelID, it.Snippet,
			p.loadContext(it.ChannelID, it.MessageTS, it.ThreadTS))
		system := fmt.Sprintf(tmpl, prompts.Directive(p.cfg.Digest.Language), brief, itemBlock)

		raw, usage, _, err := p.generator.Generate(digest.WithSource(ctx, "inbox.card"), system, "Prepare the card.", "")
		if err != nil {
			p.logger.Printf("inbox: card generation failed for item %d: %v", it.ID, err)
			_ = p.db.MarkInboxCardFailed(it.ID)
			continue
		}
		p.accumulateUsage(usage)

		var card cardResult
		if err := json.Unmarshal([]byte(prompts.ExtractJSONObject(raw)), &card); err != nil || card.WhyMatters == "" {
			p.logger.Printf("inbox: card parse failed for item %d: %v", it.ID, err)
			_ = p.db.MarkInboxCardFailed(it.ID)
			continue
		}
		if err := p.db.SetInboxCard(it.ID, card.WhyMatters, card.ThreadDigest, card.DraftReply); err != nil {
			return generated, fmt.Errorf("persisting card for item %d: %w", it.ID, err)
		}
		generated++
	}
	return generated, nil
}
```

(Adjust `it.ID` int/int64 to the actual `InboxItem.ID` type; match `p.logger` usage style from `pipeline.go`.)

- [ ] **Step 4: Run tests**

Run: `go test ./internal/inbox/ > /tmp/wt-t6.log 2>&1; echo "exit=$?"` → exit=0.

- [ ] **Step 5: Commit**

```bash
git add internal/inbox/card.go internal/inbox/card_test.go
git commit -m "feat(inbox): secretary card stage — why/digest/draft per surfaced item"
```

---

### Task 7: Rewire `Pipeline.Run`, delete the old decision core, config + wiring

**Files:**
- Modify: `internal/inbox/pipeline.go` (`Run` :188-349, `RunFastDetection` :359-412; delete `classifyNewItems` :568-598, `aiPrioritizeNewItems` :678-776, `formatItemLine` :779-822, `parseAIResult` :981-997, `aiPrioritizeResult`/`aiPrioritizeItem` :664-674, `pinnedSelector` field + construction)
- Delete: `internal/inbox/classifier.go`, `internal/inbox/classifier_test.go`, `internal/inbox/pinned_selector.go`, `internal/inbox/pinned_selector_test.go`, `internal/inbox/prompts/select_pinned.tmpl` (and the now-empty `prompts/` dir)
- Modify: `cmd/sync.go:287` area, `cmd/inbox.go:389` area (SetPromptStore wiring)
- Test: `internal/inbox/pipeline_test.go`, `internal/inbox/e2e_test.go`, `internal/inbox/pipeline_extra_test.go`

**Interfaces:**
- Consumes: `runTriage` (Task 5), `runCards` (Task 6).
- Produces: new `Run` phase order below (config fields `MaxTriageMessages`/`MaxAwarenessCards` already exist from Task 5).
- `DefaultItemClass`/`ApplyAIOverride` from `classifier.go` are deleted — `CreateInboxItem`'s `actionable` default plus triage demotion replace them. `RunFastDetection` keeps working unchanged except the `classifyNewItems` call is removed.

New `Run` phase order (replaces :226-340):

```
0. dedup                      p.db.DeduplicateThreadInboxItems()
1. detect                     detectAll(...)                      → detectErr
2. triage                     newItems = pending with AIReason==""; runTriage(...) → outcome, triageErr
3. learn                      RunImplicitLearner(...)
4. auto-resolve               p.autoResolveByRules(...)
5. cards                      runCards(...)                        (failures non-fatal)
6. archive                    ArchiveExpiredAmbient / ArchiveStaleActionable
7. unsnooze                   UnsnoozeExpiredInboxItems
8. watermark:
     if detectErr != nil || triageErr != nil → freeze, except:
       if triageErr == nil && outcome.Capped        → advance to outcome.MaxProcessedTS
       if triageErr != nil && outcome.MaxProcessedTS > lastTS
                                                    → advance to outcome.MaxProcessedTS
                                                      (chunks before the failure are done)
     else if outcome.Capped                         → advance to outcome.MaxProcessedTS
     else                                           → advance to now-30min (existing buffer logic :327-340)
     never below lastTS (existing clamp)
```

- [ ] **Step 1: Update guard + pipeline tests first (they define the contract)**

In `internal/inbox/pipeline_test.go` / `e2e_test.go`:
- Replace mock responses shaped for `inbox.prioritize`/pinned (`{"items":[...]}`, `{"pinned_ids":[]}`) with triage/card JSON.
- `TestInbox09_WatermarkFrozenOnDetectorError` must keep passing unchanged.
- Add:

```go
func TestInbox09_WatermarkFrozenOnTriageError(t *testing.T) {
	// generator errors on the triage call → Run returns the error,
	// GetInboxLastProcessedTS() == value before Run.
}

func TestInbox09_CappedTriageAdvancesWatermarkPartially(t *testing.T) {
	// cfg.Inbox.MaxTriageMessages = 2, three stream messages at ts 101/102/103,
	// triage succeeds → watermark == 102 (not now-30min, not frozen).
}

func TestInbox03_StreamSignalSurfaced(t *testing.T) {
	// e2e: message without any mention, triage says action → pending inbox item
	// with trigger_type=stream exists after Run. (This closes the INBOX-03 gap.)
}

func TestInbox07_FeedUntouchedOnTriageError(t *testing.T) {
	// Existing pending items keep status/priority/class when triage errors.
}
```

- Delete tests that pin the old mechanics: `TestInbox01_DefaultClassByTrigger`, `TestInbox01_AINeverUpgrades` (classifier_test.go — replaced by `TestInbox01_TriggerNeverIgnored` + `TestInbox01_TriageNeverUpgrades` from Task 5), `TestInbox03_MutedSourcesNotPinned`, `TestInbox07_PinnedKeepsStateOnAIError`, `TestInbox07_PinnedKeepsStateOnInvalidJSON` (pinned_selector_test.go — replaced by Task 5/6 guards + the two above). **These are owner-approved removals per the spec; do not remove anything else from the guard set.** `TestInbox03_UserPrefsRankedByRelevance` (user_preferences_test.go) stays.

- [ ] **Step 2: Run to verify the new tests fail**

Run: `go test ./internal/inbox/ > /tmp/wt-t7.log 2>&1; echo "exit=$?"` → exit=1.

- [ ] **Step 3: Implement the rewire**

- `Run`: implement the phase order above. Progress reporting: keep `p.progress(step, total, status)` with `total = 7` and statuses `"detecting"`, `"triaging"`, `"learning"`, `"auto-resolving"`, `"preparing cards"`, `"archiving"`, `"done"`.
- `RunFastDetection`: delete the `classifyNewItems` call; everything else stays (fast-detected items surface as `actionable`/`medium` until the next full `Run` triages them).
- Delete the files/functions listed in **Files**. Remove the `pinnedSelector` field from `Pipeline` and its construction in `New`.
- Config fields already exist (added in Task 5). Note: `MaxItemsPerRun` was already dead code — leave it alone in this task.
- Wiring: after `inbox.New(...)` in `cmd/sync.go` (:287) and `cmd/inbox.go` (:389), add `inboxPipe.SetPromptStore(promptStore)` mirroring how `dayPlanPipe.SetPromptStore` is wired nearby (find the `prompts.NewStore`/store variable already in scope in each file; if `cmd/inbox.go` has none, construct it the same way `cmd/sync.go` does).

- [ ] **Step 4: Run the full backend suite**

Run: `go build ./... && go vet ./... > /tmp/wt-t7.log 2>&1; echo "exit=$?"` → exit=0.
Run: `go test ./internal/inbox/ ./internal/db/ ./internal/config/ ./cmd/... > /tmp/wt-t7.log 2>&1; echo "exit=$?"` → exit=0.
Also grep for leftovers: `grep -rn "inbox.prioritize\|pinnedSelector\|select_pinned\|DefaultItemClass" internal/ cmd/ --include="*.go"` — expect only `prompts` registration hits (removed in Task 8).

- [ ] **Step 5: Commit**

```bash
git add -A internal/inbox/ internal/config/ cmd/
git commit -m "feat(inbox): two-stage secretary pipeline replaces classifier/prioritize/pinned"
```

---

### Task 8: Migration 00010 — drop `pinned`, deregister `inbox.prioritize`

**Files:**
- Create: `internal/db/migrations/00010_drop_inbox_pinned.sql`
- Modify: `internal/db/schema.sql` (remove `pinned` column + `idx_inbox_items_pinned`)
- Modify: `internal/db/models.go` (remove `InboxItem.Pinned`), `internal/db/inbox.go` (remove `pinned` from column consts/scanners; delete `SetInboxPinned` :659, `ClearPinnedAll` :677, `ListInboxPinned` :735)
- Modify: `internal/prompts/store.go` (remove `InboxPrioritize` const), `internal/prompts/defaults.go` (remove `defaultInboxPrioritize` + its four map entries), `internal/digest/models.go` + `internal/codex/models.go` (remove `"inbox.prioritize"` case) + both `models_test.go`
- Modify: `internal/db/testdata/schema_v73.golden` (regenerated)
- Test: `internal/db/inbox_test.go` (remove pinned-func tests)

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
DROP INDEX IF EXISTS idx_inbox_items_pinned;
ALTER TABLE inbox_items DROP COLUMN pinned;
DELETE FROM prompts WHERE id = 'inbox.prioritize';

-- +goose Down
ALTER TABLE inbox_items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_inbox_items_pinned ON inbox_items(pinned) WHERE pinned = 1;
```

(Verify the exact original index definition against `schema.sql` before writing the Down.)

- [ ] **Step 2: Remove Go references**

Remove the struct field, scanner column, and the three pinned functions plus their tests; remove the prompt registration and routing entries (including the `{"inbox.prioritize", ...}` rows in both `models_test.go` tables). Mirror `schema.sql`.

- [ ] **Step 3: Regenerate golden + verify**

Run: `go test ./internal/db/ -run TestSchemaGolden -update > /tmp/wt-t8.log 2>&1; echo "exit=$?"`
Run: `go build ./... && go test ./internal/db/ ./internal/inbox/ ./internal/prompts/ ./internal/digest/ ./internal/codex/ > /tmp/wt-t8.log 2>&1; echo "exit=$?"` → exit=0.
Grep: `grep -rni "pinned" internal/ cmd/ --include="*.go"` → no inbox hits (other features' unrelated hits are fine).

- [ ] **Step 4: Commit**

```bash
git add -A internal/
git commit -m "feat(db,prompts): drop inbox pinned column, deregister inbox.prioritize"
```

---

### Task 9: Desktop — model, test schema, queries, ViewModel, two-tier feed

**Files:**
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift:481-518` (inbox_items DDL), `:1149` (`insertInboxItem` helper), workspace DDL (add `secretary_profile`)
- Modify: `WatchtowerDesktop/Sources/Models/InboxItem.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift`, `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift`
- Test: `WatchtowerDesktop/Tests/InboxItemTests.swift`, `InboxQueriesTests.swift`, `InboxViewModelTests.swift`

**Interfaces:**
- Consumes: post-00010 schema (no `pinned`; five card columns; `trigger_type` includes `stream`).
- Produces:
  - `InboxItem`: drop `pinned`; add `let whyMatters: String`, `let threadDigest: String`, `let draftReply: String`, `let cardStatusRaw: String`, `let cardGeneratedAt: Date?`; `enum CardStatus: String { case none, ready, failed }`; `var cardStatus: CardStatus { CardStatus(rawValue: cardStatusRaw) ?? .none }`; `var hasCard: Bool { cardStatus == .ready }`.
  - `InboxQueries.fetchActionTier(_ db: Database, unreadOnly: Bool, keepIDs: Set<Int>) throws -> [InboxItem]` — `item_class='actionable' AND status='pending' AND archived_at IS NULL`, ordered high→low priority then `updated_at DESC` (reuse `fetchPinned`'s unreadOnly/keepIDs semantics from :158-188).
  - `InboxQueries.fetchAwarenessTier(_ db: Database, limit: Int, offset: Int, unreadOnly: Bool, keepIDs: Set<Int>) throws -> [InboxItem]` — same shape as old `fetchFeed` (:189) but `item_class='ambient'` instead of `pinned=0`.
  - `InboxQueries.hasHighPriorityAction(_ db: Database) throws -> Bool` — old `hasHighPriorityPinned` (:219) with `item_class='actionable'` predicate. Delete `fetchPinned`, `fetchFeed`, `hasHighPriorityPinned`, `observePinned`.
  - `InboxViewModel`: rename `pinnedItems` → `actionItems`, `feedItems` → `awarenessItems`, `hasHighPriorityPinned` → `hasHighPriorityAction`; `load()` calls the new queries.

- [ ] **Step 1: Update TestDatabase.swift first**

Mirror the post-00010 `inbox_items` DDL from `internal/db/schema.sql` verbatim (add `'stream'` to the CHECK, add the five card columns, remove `pinned`) and add `secretary_profile TEXT NOT NULL DEFAULT ''` to the embedded `workspace` DDL. Keep `PRAGMA user_version = 5`. Extend `insertInboxItem` (:1149) with optional parameters `itemClass: String = "actionable"`, `cardStatus: String = "none"`, `whyMatters: String = ""`, `threadDigest: String = ""`, `draftReply: String = ""`. **This is the known drift spot (see memory: TestDatabase.swift vs schema.sql divergence) — copy from schema.sql, do not retype.**

- [ ] **Step 2: Write failing Swift tests**

`InboxQueriesTests.swift`:

```swift
func test_fetchActionTier_returnsOnlyActionableOrderedByPriority() throws {
    // insert: actionable/high, actionable/low, ambient/high
    // assert fetchActionTier returns 2 items, high first, no ambient
}

func test_fetchAwarenessTier_paginatesAmbientOnly() throws { /* mirror old fetchFeed test with item_class */ }

func test_inboxItem_mapsCardColumns() throws {
    // insertInboxItem(cardStatus: "ready", whyMatters: "w", threadDigest: "t", draftReply: "d")
    // fetch → item.cardStatus == .ready, item.whyMatters == "w", item.hasCard
}
```

`InboxViewModelTests.swift`: rewrite the pinned/feed cases (`InboxViewModelPinnedFeedTests` :7) into action/awareness equivalents: `vm.actionItems` / `vm.awarenessItems` populated by class, counts unchanged.

- [ ] **Step 3: Run to verify failure**

Run: `cd WatchtowerDesktop && swift build > /tmp/wt-t9.log 2>&1; echo "exit=$?"` → exit=1 (or `swift test` failures once it compiles).

- [ ] **Step 4: Implement**

- `InboxItem.swift`: apply the model changes (`card_generated_at` parses with the same ISO8601 handling as `archived_at` :79-84).
- `InboxQueries.swift`: implement the three new funcs; delete the four pinned-era ones.
- `InboxViewModel.swift`: rename properties, update `load()` (:119-193) to call `fetchActionTier`/`fetchAwarenessTier`/`hasHighPriorityAction`; keep pagination on the awareness tier only.
- `InboxFeedView.swift`: replace the Pinned section (:150-155) with `sectionHeader("Needs action")` + `ForEach(vm.actionItems)` at `.pinned` card size (rename the enum case to `.expanded` — mechanical rename in `InboxCardView.CardSize`), and the day-grouped feed (:157-162) now iterates `vm.awarenessItems` under `sectionHeader("FYI")` (keep day grouping). `cardSize(for:)` (:269): actionable → `.expanded`, ambient → `.compact`.
- `InboxCardView.swift`: mechanical updates only (enum rename, drop `item.pinned` checks :52/:69 — action-tier styling now keys off `item.itemClass == .actionable`). The secretary-card content itself is Task 10.

- [ ] **Step 5: Build, test, commit**

Run: `cd WatchtowerDesktop && swift build > /tmp/wt-t9.log 2>&1; echo "exit=$?"` → exit=0.
Run: `cd WatchtowerDesktop && swift test > /tmp/wt-t9.log 2>&1; echo "exit=$?"` → exit=0. Then `make lint-swift` from repo root.

```bash
git add WatchtowerDesktop/
git commit -m "feat(desktop): two-tier inbox (Needs action / FYI) replaces pinned+feed"
```

---

### Task 10: Desktop — secretary card UI

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift`
- Test: `WatchtowerDesktop/Tests/InboxItemTests.swift` (model-level card logic), `WatchtowerDesktop/Tests/InboxViewModelTests.swift`

**Interfaces:**
- Consumes: `InboxItem.cardStatus/.whyMatters/.threadDigest/.draftReply/.hasCard` (Task 9); NSPasteboard copy pattern from `MessageBubble.swift:80-87` (`copyMessage()` + animated `cornerCopyButton` :62-73).
- Produces: expanded card body for action-tier (and expanded awareness) rows:
  - `hasCard == true` → "Why it matters" paragraph, "Thread digest" paragraph, draft-reply block in a bordered `GroupBox`-style container with a Copy button (`NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.draftReply, forType: .string)` with the `didCopy` checkmark animation).
  - `hasCard == false && item.itemClass == .actionable` → placeholder row: `ProgressView().controlSize(.small)` + `Text("Preparing context…")` (follow the loading idiom at `InboxCardView.swift:257-264`); if `cardStatus == .failed` show `Text("Context unavailable — will retry")` with a `.secondary` style instead of a spinner.
  - The existing inline `conversationSection` stays (raw thread on demand); the digest does not replace it.

- [ ] **Step 1: Write failing tests**

Model-level (no snapshot infra in repo — test the logic, not pixels):

```swift
func test_cardPresentation_states() throws {
    // hasCard: ready+non-empty → true; none → false; failed → false
    // (drive via insertInboxItem variants + fetch, or direct InboxItem construction)
}
```

Plus a ViewModel-level assertion that `load()` surfaces card fields (insert ready-card item → `vm.actionItems[0].draftReply == "d"`).

- [ ] **Step 2: Implement the card body in `InboxCardView`**

Add a `secretaryCardSection` view builder rendering the three blocks per the interface above; call it from the expanded layout (where the AI-reason block renders today, :129-140) for items with `hasCard`, and the placeholder for actionable items without. Keep `ai_reason` visible as the one-line hint on compact rows (it now carries the triage reason).

- [ ] **Step 3: Build, test, commit**

Run: `cd WatchtowerDesktop && swift build && swift test > /tmp/wt-t10.log 2>&1; echo "exit=$?"` → exit=0.

```bash
git add WatchtowerDesktop/
git commit -m "feat(desktop): secretary card UI — why it matters, digest, copyable draft reply"
```

---

### Task 11: Desktop — Profile editor tab

**Files:**
- Create: `WatchtowerDesktop/Sources/Database/Queries/SecretaryProfileQueries.swift`
- Create: `WatchtowerDesktop/Sources/Views/Inbox/SecretaryProfileView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift` (:12 `Tab` enum, :34-43 body switch, :109-113 picker)
- Test: `WatchtowerDesktop/Tests/SecretaryProfileQueriesTests.swift`

**Interfaces:**
- Produces:

```swift
enum SecretaryProfileQueries {
    static func fetch(_ db: Database) throws -> String        // SELECT secretary_profile FROM workspace LIMIT 1 (empty string if no row)
    static func save(_ db: Database, text: String) throws     // UPDATE workspace SET secretary_profile = ?
}
```

  `InboxFeedView.Tab` gains `case profile`; the segmented picker shows Feed / Learned / Profile. `SecretaryProfileView(db: DatabasePool)` follows the `ProfileSettings.swift` idiom: a `TextEditor` bound to `@State var text`, loaded in `.task`, with a bottom `safeAreaInset` Save bar and a transient "Saved" confirmation. Add a short caption above the editor: `Text("Tell the secretary who you are and what matters. It reads this before every scan.")`.

- [ ] **Step 1: Write failing tests**

```swift
final class SecretaryProfileQueriesTests: XCTestCase {
    func test_fetch_emptyByDefault_and_saveRoundTrip() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.pool.write { db in
            XCTAssertEqual(try SecretaryProfileQueries.fetch(db), "")
            try SecretaryProfileQueries.save(db, text: "I own direction X")
            XCTAssertEqual(try SecretaryProfileQueries.fetch(db), "I own direction X")
        }
    }
}
```

(Match the actual `TestDatabase.createDatabaseManager()` return shape and pool accessor used by neighboring query tests; ensure the workspace fixture row exists — check how other tests seed `workspace`.)

- [ ] **Step 2: Implement queries, view, tab wiring**

- [ ] **Step 3: Build, test, commit**

Run: `cd WatchtowerDesktop && swift build && swift test > /tmp/wt-t11.log 2>&1; echo "exit=$?"` → exit=0.

```bash
git add WatchtowerDesktop/
git commit -m "feat(desktop): secretary profile editor tab in inbox"
```

---

### Task 12: Docs, inventory, app guide

**Files:**
- Modify: `docs/inventory/inbox-pulse.md`
- Modify: `docs/app-guide.md` (`### Inbox` :24-57 + cross-refs :12, :107, :111, :234, :240, :249)
- Modify: `CLAUDE.md` (Inbox Pulse feature note)

- [ ] **Step 1: Rewrite `docs/inventory/inbox-pulse.md`**

- **INBOX-01** → "Two tiers: action vs awareness". Same promise (visual split, AI may only downgrade); guards now `internal/inbox/triage_test.go::TestInbox01_TriggerNeverIgnored` and `::TestInbox01_TriageNeverUpgrades`.
- **INBOX-03** → Status: **Enforced** (gap closed by full-stream triage). Guards: `internal/inbox/e2e_test.go::TestInbox03_StreamSignalSurfaced`, `internal/inbox/triage_test.go::TestTriage_HardMutedStreamCandidateSkipped`, existing `TestInbox03_UserPrefsRankedByRelevance`. Remove the "Tracked gap" paragraph.
- **INBOX-07** → "AI failure does not lose state" now covers triage (feed untouched, guard `TestInbox07_FeedUntouchedOnTriageError`, `TestInbox07_InvalidJSONLeavesStateUntouched`) and cards (item keeps snippet, retries; guards `TestInbox07_CardFailureMarksFailedAndContinues`, `TestRunCards_InvalidJSONMarksFailed`).
- **INBOX-09** → add the partial-advance rule: on a capped or partially-failed triage the watermark advances exactly to the last fully-triaged message (`TestInbox09_WatermarkFrozenOnTriageError`, `TestInbox09_CappedTriageAdvancesWatermarkPartially`).
- INBOX-02/04/05/06 unchanged.
- Changelog entry: `2026-07-05: secretary redesign (owner-approved, spec docs/superpowers/specs/2026-07-05-inbox-secretary-redesign-design.md) — INBOX-01/07 rewritten for triage+cards, INBOX-03 closed, pinned guards retired.`

- [ ] **Step 2: Update `docs/app-guide.md`**

Rewrite the Inbox section: two tiers ("Needs action" expanded cards with why-it-matters / thread digest / copyable draft reply; "FYI" compact rows), "Preparing context…" placeholder, Feed/Learned/Profile tabs, snooze options 1h/tomorrow/Monday (fix the stale "1 day / 3 days / 1 week" text at :47 while there), remove the detail-view mention (:39).

- [ ] **Step 3: Update `CLAUDE.md`**

Replace the "Inbox Pulse (v67+)" phase list with: detectors → full-stream triage (`inbox.triage`, cheap tier) → learner → auto-resolve → secretary cards (`inbox.card`, strong tier) → archive/unsnooze; note the pinned column/selector removal and the `workspace.secretary_profile` brief.

- [ ] **Step 4: Commit**

```bash
git add docs/ CLAUDE.md
git commit -m "docs: inbox secretary — inventory contracts, app guide, developer notes"
```

---

### Final verification (before PR)

- [ ] `go build ./... && go vet ./... > /tmp/wt-final.log 2>&1; echo "exit=$?"` → exit=0
- [ ] `go test ./... > /tmp/wt-final.log 2>&1; echo "exit=$?"` → exit=0
- [ ] `cd WatchtowerDesktop && swift build && swift test > /tmp/wt-final-swift.log 2>&1; echo "exit=$?"` → exit=0
- [ ] Run the `local-review` skill on the branch (CI mirror + review panel) before opening the PR; PR description in English.
- [ ] Manual smoke: `watchtower inbox generate` against a synced DB — confirm stream items appear, cards fill in, `inbox` CLI list renders.
