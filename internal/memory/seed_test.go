package memory

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedTestConfig is the config used by the seeding tests: a small explicit
// threshold over the standard 30-day window.
var seedTestConfig = SeedConfig{MinMessages: 3, WindowDays: 30}

// seedUser inserts a users row.
func seedUser(t *testing.T, d *db.DB, id, displayName, email string, isBot int) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO users (id, name, display_name, email, is_bot) VALUES (?, ?, ?, ?, ?)`,
		id, "name-"+id, displayName, email, isBot)
	require.NoError(t, err)
}

// seedChannel inserts a channels row.
func seedChannel(t *testing.T, d *db.DB, id, name, topic, purpose string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO channels (id, name, type, topic, purpose) VALUES (?, ?, 'public', ?, ?)`,
		id, name, topic, purpose)
	require.NoError(t, err)
}

// seedMsgSeq keeps seeded message timestamps unique across seedMessages calls
// within one test (messages PK is channel_id+ts).
var seedMsgSeq int

// seedMessages inserts count recent messages from userID into channelID.
func seedMessages(t *testing.T, d *db.DB, channelID, userID string, count int) {
	t.Helper()
	base := time.Now().Add(-time.Hour).Unix()
	for range count {
		seedMsgSeq++
		ts := fmt.Sprintf("%d.%06d", base, seedMsgSeq)
		_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, ?, ?)`,
			channelID, ts, userID, "message "+ts)
		require.NoError(t, err)
	}
}

// seedPeopleCard inserts a people_cards row and returns its ID.
func seedPeopleCard(t *testing.T, d *db.DB, userID, summary string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO people_cards (user_id, period_from, period_to, summary) VALUES (?, 0, 1, ?)`,
		userID, summary)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// seedJiraIssue inserts a minimal jira_issues row (account 1) for a project key.
func seedJiraIssue(t *testing.T, d *db.DB, key, projectKey string) {
	t.Helper()
	seedJiraAccount(t, d)
	_, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES (1, ?, ?, 'issue', 'Open', 'To Do', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`,
		key, projectKey)
	require.NoError(t, err)
}

func TestSeedPersonNodeShape(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice Adams", "alice@example.com", 0)
	seedChannel(t, d, "C1GEN", "general", "General chat", "")
	seedMessages(t, d, "C1GEN", "U1ALICE", 5)
	cardID := seedPeopleCard(t, d, "U1ALICE", "Team lead for billing.")

	created, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 2, created, "one person + one channel")

	n, err := Resolve(v, d, "U1ALICE")
	require.NoError(t, err)
	assert.Equal(t, "entity", n.Type)
	assert.Equal(t, "long", n.Tier)
	assert.Equal(t, "active", n.Status)
	assert.Equal(t, "Alice Adams", n.Title)
	assert.Contains(t, n.Body, "# Alice Adams\n")
	assert.Contains(t, n.Aliases, "U1ALICE")
	assert.Contains(t, n.Aliases, "alice@example.com")
	assert.Equal(t, cardID, n.Refs.PeopleCard)
	assert.Contains(t, n.Body, "## What\nTeam lead for billing.\n", "What filled from the people card summary")
	for _, section := range []string{"## What", "## Current", "## Facts", "## Links", "## Open loops"} {
		assert.Contains(t, n.Body, section+"\n", "empty section %q present", section)
	}
}

func TestSeedPersonWithoutCardOrEmail(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U2BOB", "Bob", "", 0)
	seedChannel(t, d, "C1GEN", "general", "", "")
	seedMessages(t, d, "C1GEN", "U2BOB", 3)

	_, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)

	n, err := Resolve(v, d, "U2BOB")
	require.NoError(t, err)
	assert.Equal(t, []string{"U2BOB"}, n.Aliases, "no email alias when the users row has none")
	assert.Zero(t, n.Refs.PeopleCard)
	assert.Contains(t, n.Body, "## What\n\n", "What left empty without a people card")
}

func TestSeedChannelNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice", "", 0)
	seedChannel(t, d, "C2DEPLOY", "deploys", "Deploy announcements", "Ship it")
	seedMessages(t, d, "C2DEPLOY", "U1ALICE", 1)

	_, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)

	n, err := Resolve(v, d, "C2DEPLOY")
	require.NoError(t, err)
	assert.Equal(t, []string{"C2DEPLOY"}, n.Aliases)
	assert.Equal(t, "#deploys", n.Title)
	assert.Contains(t, n.Body, "## What\nDeploy announcements\n", "What from channel topic")
	assert.Equal(t, "long", n.Tier)
	assert.Equal(t, "active", n.Status)
}

func TestSeedChannelWhatFallsBackToPurpose(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice", "", 0)
	seedChannel(t, d, "C3OPS", "ops", "", "Operational firefighting")
	seedMessages(t, d, "C3OPS", "U1ALICE", 1)

	_, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)

	n, err := Resolve(v, d, "C3OPS")
	require.NoError(t, err)
	assert.Contains(t, n.Body, "## What\nOperational firefighting\n")
}

func TestSeedJiraProjectNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedJiraIssue(t, d, "PROJX-1", "PROJX")
	seedJiraIssue(t, d, "PROJX-2", "PROJX")

	created, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, created, "distinct project keys, not one node per issue")

	n, err := Resolve(v, d, "PROJX")
	require.NoError(t, err)
	assert.Equal(t, []string{"PROJX"}, n.Aliases)
	assert.Equal(t, "PROJX", n.Title)
}

func TestSeedThresholdAndBotRespected(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U3QUIET", "Quiet Quinn", "", 0)
	seedUser(t, d, "U4BOT", "Bot Barry", "", 1)
	seedChannel(t, d, "C1GEN", "general", "", "")
	seedMessages(t, d, "C1GEN", "U3QUIET", 2) // below MinMessages=3
	seedMessages(t, d, "C1GEN", "U4BOT", 10)  // bot: excluded regardless of volume

	_, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)

	_, err = Resolve(v, d, "U3QUIET")
	assert.ErrorIs(t, err, ErrNotFound, "below-threshold user not seeded")
	_, err = Resolve(v, d, "U4BOT")
	assert.ErrorIs(t, err, ErrNotFound, "bot not seeded")
}

func TestSeedIdempotentSecondRun(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice", "alice@example.com", 0)
	seedChannel(t, d, "C1GEN", "general", "Topic", "")
	seedMessages(t, d, "C1GEN", "U1ALICE", 4)
	seedJiraIssue(t, d, "PROJX-1", "PROJX")

	created, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 3, created)

	repo := openTestRepo(t, v.path)
	commitsAfterFirst := commitCount(t, repo)
	nodesAfterFirst, err := d.ListMemoryNodes()
	require.NoError(t, err)

	created, err = SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "second run creates nothing")

	assert.Equal(t, commitsAfterFirst, commitCount(t, repo), "no new commit when nothing to create")
	nodesAfterSecond, err := d.ListMemoryNodes()
	require.NoError(t, err)
	assert.Equal(t, len(nodesAfterFirst), len(nodesAfterSecond), "node count unchanged")
}

// gmailTestAccountID is the account id single-account Gmail extraction tests
// seed their messages under — the test-only replacement for the deleted
// production stubGoogleAccountID (multi-account plan Task 9: the extractor
// itself no longer hardcodes an account id, it loops db.ListGoogleAccounts).
const gmailTestAccountID = int64(1)

// seedGmailMessage inserts a gmail_messages row under gmailTestAccountID —
// the single-account convenience wrapper most Gmail extraction tests use.
// internalDateISO is the RFC3339 message time (what the Gmail sync stores —
// NOT the raw ms-epoch API value).
func seedGmailMessage(t *testing.T, d *db.DB, id, threadID, fromEmail, fromName, subject, body, internalDateISO string) {
	t.Helper()
	seedGmailMessageForAccount(t, d, gmailTestAccountID, id, threadID, fromEmail, fromName, subject, body, internalDateISO)
}

// seedGmailMessageForAccount is seedGmailMessage generalized to an explicit
// account id, seeding that google_accounts row first (idempotent, Gmail
// enabled) since gmail_messages.account_id is a NOT NULL FK — the
// multi-account Gmail-extraction tests (Task 9) seed two accounts this way to
// prove their watermarks advance independently.
func seedGmailMessageForAccount(t *testing.T, d *db.DB, accountID int64, id, threadID, fromEmail, fromName, subject, body, internalDateISO string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO google_accounts (id, email, label, gmail_enabled) VALUES (?, ?, 'Stub', 1)
		ON CONFLICT(id) DO UPDATE SET gmail_enabled = 1`, accountID, fmt.Sprintf("stub%d@x.com", accountID))
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO gmail_messages
		(account_id, id, thread_id, from_email, from_name, subject, body_text, internal_date)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		accountID, id, threadID, fromEmail, fromName, subject, body, internalDateISO)
	require.NoError(t, err)
}

// recentISO renders an RFC3339 timestamp offsetSeconds after an hour ago — a
// gmail internal_date inside the 30-day seed/extract window.
func recentISO(offsetSeconds int) string {
	return time.Now().Add(-time.Hour).Add(time.Duration(offsetSeconds) * time.Second).UTC().Format(time.RFC3339)
}

// seedGmailTestConfig is seedTestConfig with the Gmail sender source ON.
var seedGmailTestConfig = SeedConfig{MinMessages: 3, WindowDays: 30, Gmail: true}

// gmailSeedSeq gives each seeded gmail message a process-unique id so repeated
// seedGmailSenderN calls (e.g. below- then above-threshold) never collide.
var gmailSeedSeq int

// seedGmailSenderN inserts n messages from one sender (distinct ids/threads) so
// a sender can cross the MinMessages seed threshold.
func seedGmailSenderN(t *testing.T, d *db.DB, email, name string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		gmailSeedSeq++
		id := fmt.Sprintf("%s-m%d", email, gmailSeedSeq)
		seedGmailMessage(t, d, id, id, email, name, "Subj", "body", recentISO(gmailSeedSeq))
	}
}

// TestSeedGmailSenderNewPerson: a distinct external from_email that sent at
// least MinMessages messages in the window becomes a person entity aliased by
// its (lower-cased) email, titled from from_name.
func TestSeedGmailSenderNewPerson(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "Ext.Sender@Example.com", "External Sender", 3)

	created, err := SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, created, "one external sender → one person entity")

	n, err := Resolve(v, d, "ext.sender@example.com")
	require.NoError(t, err)
	assert.Equal(t, "entity", n.Type)
	assert.Equal(t, "External Sender", n.Title)
	assert.Contains(t, n.Aliases, "ext.sender@example.com", "aliased by the lower-cased email")
}

// TestSeedGmailSenderBelowThresholdSkipped: a human sender under the MinMessages
// floor is not seeded; the same sender at/above the floor is (the noise gate #2).
func TestSeedGmailSenderBelowThresholdSkipped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "sparse@example.com", "Sparse", 2) // below MinMessages=3

	created, err := SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "a below-threshold sender is not seeded")

	seedGmailSenderN(t, d, "sparse@example.com", "Sparse", 3) // now 5 total, over the floor
	created, err = SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, created, "the same sender is seeded once it clears the floor")
}

// TestSeedGmailSenderMachineSenderDropped: an automated sender (no-reply@) is
// never seeded no matter how high its volume (the machine-sender pattern gate).
func TestSeedGmailSenderMachineSenderDropped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "no-reply@vendor.io", "Vendor Bot", 25) // high volume
	seedGmailSenderN(t, d, "notifications@github.com", "GitHub", 10)

	created, err := SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "machine senders are dropped regardless of volume")

	_, err = Resolve(v, d, "no-reply@vendor.io")
	require.Error(t, err, "no-reply@ is never a person entity")
}

// TestSeedGmailSenderTitleFallsBackToLocalPart: a sender with no from_name is
// titled from the local-part of its email.
func TestSeedGmailSenderTitleFallsBackToLocalPart(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "billing@vendor.io", "", 3)

	_, err := SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)

	n, err := Resolve(v, d, "billing@vendor.io")
	require.NoError(t, err)
	assert.Equal(t, "billing", n.Title, "local-part fallback")
}

// TestSeedGmailSenderStitchedToSlackPerson: a from_email equal to an
// already-seeded Slack user's email creates NO second entity — the existing
// person's email alias (seedPeople) stitches the sender via LookupMemoryAlias.
func TestSeedGmailSenderStitchedToSlackPerson(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice Adams", "alice@example.com", 0)
	seedChannel(t, d, "C1GEN", "general", "", "")
	seedMessages(t, d, "C1GEN", "U1ALICE", 3)
	// Alice also appears as a high-volume Gmail sender (case-differing) — must NOT duplicate.
	seedGmailSenderN(t, d, "Alice@example.com", "Alice A.", 4)

	created, err := SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 2, created, "alice (person) + #general — NO duplicate for the gmail sender")

	// Both the user id and the gmail-cased email resolve to the SAME node.
	byID, err := Resolve(v, d, "U1ALICE")
	require.NoError(t, err)
	byEmail, err := Resolve(v, d, "Alice@example.com")
	require.NoError(t, err)
	assert.Equal(t, byID.ID, byEmail.ID, "gmail sender unified with the Slack person")
}

// TestSeedGmailSenderGateOff: with the Gmail source dark (SeedConfig.Gmail
// false), no sender is seeded even at high volume — the source is literally dark.
func TestSeedGmailSenderGateOff(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "ext@example.com", "Ext", 10)

	created, err := SeedEntities(v, d, seedTestConfig, nil) // Gmail: false
	require.NoError(t, err)
	assert.Zero(t, created, "no senders seeded when the gmail source is off")
}

// TestSeedGmailSenderIdempotent: re-running SeedEntities creates no second
// entity for the same sender.
func TestSeedGmailSenderIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "sender@example.com", "Sender", 3)

	created, err := SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	require.Equal(t, 1, created)

	created, err = SeedEntities(v, d, seedGmailTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "second run creates nothing")
}

// TestSeedGmailSenderOutsideWindowSkipped: a sender whose only message predates
// the seed window is not seeded.
func TestSeedGmailSenderOutsideWindowSkipped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	old := time.Now().AddDate(0, 0, -60).UTC().Format(time.RFC3339)
	seedGmailMessage(t, d, "m1", "t1", "stale@example.com", "Stale", "Hi", "body", old)

	created, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "out-of-window sender not seeded")
}

// seedCalendarTestConfig is seedTestConfig with the calendar series source ON.
var seedCalendarTestConfig = SeedConfig{MinMessages: 3, WindowDays: 30, Calendar: true}

// calEvent is a compact spec for a seeded calendar_events row (shared by the
// seed and calendar-ingest tests).
type calEvent struct {
	id            string
	calendarID    string
	title         string
	description   string
	location      string
	organizer     string
	start         string // ISO8601
	end           string // ISO8601
	attendeesJSON string // JSON array; defaults to "[]"
	isRecurring   bool
	rawJSON       string // defaults to "{}"
}

// seedCalendarEvent inserts a calendar_events row (creating its calendar first,
// since calendar_id is an FK). Sensible defaults keep call sites terse.
func seedCalendarEvent(t *testing.T, d *db.DB, ev calEvent) {
	t.Helper()
	if ev.calendarID == "" {
		ev.calendarID = "cal1"
	}
	require.NoError(t, d.UpsertCalendar(0, db.CalendarCalendar{ID: ev.calendarID, Name: "C", SyncedAt: "2026-01-01T00:00:00Z"}))
	attendees := ev.attendeesJSON
	if attendees == "" {
		attendees = "[]"
	}
	rawJSON := ev.rawJSON
	if rawJSON == "" {
		rawJSON = "{}"
	}
	require.NoError(t, d.UpsertCalendarEvent(db.CalendarEvent{
		ID: ev.id, CalendarID: ev.calendarID, Title: ev.title,
		Description: ev.description, Location: ev.location, OrganizerEmail: ev.organizer,
		StartTime: ev.start, EndTime: ev.end, Attendees: attendees,
		IsRecurring: ev.isRecurring, RawJSON: rawJSON,
	}))
}

// TestSeedCalendarSeries: two recurring instances sharing one recurringEventId
// seed exactly ONE calseries entity, titled from the series' event title.
func TestSeedCalendarSeries(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "Weekly Sync", start: "2026-07-08T10:00:00Z", end: "2026-07-08T10:30:00Z", isRecurring: true, rawJSON: `{"recurringEventId":"series-A"}`})
	seedCalendarEvent(t, d, calEvent{id: "evt-2", title: "Weekly Sync", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z", isRecurring: true, rawJSON: `{"recurringEventId":"series-A"}`})

	created, err := SeedEntities(v, d, seedCalendarTestConfig, nil)
	require.NoError(t, err)
	assert.Equal(t, 1, created, "two instances of one series → one calseries entity")

	n, err := Resolve(v, d, "calseries:series-A")
	require.NoError(t, err)
	assert.Equal(t, "entity", n.Type)
	assert.Equal(t, "long", n.Tier)
	assert.Equal(t, "Weekly Sync", n.Title)
	assert.Contains(t, n.Aliases, "calseries:series-A")
}

// TestSeedCalendarSeriesNonRecurringNone: a non-recurring event, and a
// recurring event whose raw_json carries no recurringEventId, seed no series.
func TestSeedCalendarSeriesNonRecurringNone(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "One-off", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z", isRecurring: false})
	seedCalendarEvent(t, d, calEvent{id: "evt-2", title: "Rec no id", start: "2026-07-15T11:00:00Z", end: "2026-07-15T11:30:00Z", isRecurring: true, rawJSON: `{"summary":"x"}`})

	created, err := SeedEntities(v, d, seedCalendarTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "no recurringEventId → no series entity")
}

// TestSeedCalendarSeriesMalformedRawJSONSkipped: an event with malformed
// raw_json is skipped (the Gmail internal_date defensive-skip precedent), not
// an error.
func TestSeedCalendarSeriesMalformedRawJSONSkipped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "Bad", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z", isRecurring: true, rawJSON: `{not json`})

	created, err := SeedEntities(v, d, seedCalendarTestConfig, nil)
	require.NoError(t, err, "malformed raw_json is skipped, not an error")
	assert.Zero(t, created)
}

// TestSeedCalendarSeriesGateOff: with the calendar source dark
// (SeedConfig.Calendar false), no series is seeded.
func TestSeedCalendarSeriesGateOff(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "Weekly Sync", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z", isRecurring: true, rawJSON: `{"recurringEventId":"series-A"}`})

	created, err := SeedEntities(v, d, seedTestConfig, nil) // Calendar: false
	require.NoError(t, err)
	assert.Zero(t, created, "no series seeded when the calendar source is off")
}

// TestSeedCalendarSeriesIdempotent: re-running SeedEntities creates no second
// entity for the same series.
func TestSeedCalendarSeriesIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedCalendarEvent(t, d, calEvent{id: "evt-1", title: "Weekly Sync", start: "2026-07-15T10:00:00Z", end: "2026-07-15T10:30:00Z", isRecurring: true, rawJSON: `{"recurringEventId":"series-A"}`})

	created, err := SeedEntities(v, d, seedCalendarTestConfig, nil)
	require.NoError(t, err)
	require.Equal(t, 1, created)

	created, err = SeedEntities(v, d, seedCalendarTestConfig, nil)
	require.NoError(t, err)
	assert.Zero(t, created, "second run creates nothing")
}

func TestSeedCommitMessage(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice", "", 0)
	seedChannel(t, d, "C1GEN", "general", "", "")
	seedMessages(t, d, "C1GEN", "U1ALICE", 3)

	created, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err)
	require.Equal(t, 2, created)

	head := headCommit(t, openTestRepo(t, v.path))
	assert.Contains(t, head.Message, "memory(seed): 2 entities")
}

// legacyEntityNode builds a page in the shape SeedEntities writes, for tests
// that need an entity that already existed before this run.
func legacyEntityNode(title string, aliases ...string) Node {
	return Node{
		ID:      NewID("entity"),
		Type:    "entity",
		Tier:    "long",
		Status:  "active",
		Title:   title,
		Aliases: aliases,
		Body:    entitySkeletonBody(title, ""),
	}
}

// TestSeedStitchesNamespacedAliasOntoLegacyPage reproduces the 2026-08-03
// production crash (audit C2): migration 00048 namespaced users.id/channels.id,
// so a seed candidate's natural key became "1:U123" while its already-seeded
// page still carried the bare "U123" plus the person's e-mail. Matching only
// the FIRST alias missed that page, minted a duplicate, committed it to git,
// and then died on the e-mail alias's UNIQUE constraint — freezing every
// memory run from then on. The candidate must stitch onto the existing page
// instead.
func TestSeedStitchesNamespacedAliasOntoLegacyPage(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// The vault as it was seeded BEFORE 00048: the person's page is keyed by
	// the bare user id and carries her e-mail. (The channel page is already
	// namespaced — a channel candidate carries ONE alias, so a bare channel
	// page has nothing to stitch by and is simply re-created; harmless, since
	// no alias is shared, and the semantic tier's dedupe collapses it.)
	person := legacyEntityNode("Alice Adams", "U123", "a@x.test")
	channel := legacyEntityNode("#general", "1:C1GEN")
	writeAndIndex(t, v, d, person)
	writeAndIndex(t, v, d, channel)

	// The database AFTER 00048: the same person and channel, namespaced.
	seedUser(t, d, "1:U123", "Alice Adams", "a@x.test", 0)
	seedChannel(t, d, "1:C1GEN", "general", "", "")
	seedMessages(t, d, "1:C1GEN", "1:U123", 3)

	repo := openTestRepo(t, v.path)
	commitsBefore := commitCount(t, repo)

	created, err := SeedEntities(v, d, seedTestConfig, nil)
	require.NoError(t, err, "the namespaced candidate must not collide on the e-mail alias")
	assert.Zero(t, created, "both candidates stitch onto existing pages, nothing is created")

	byNamespaced, err := Resolve(v, d, "1:U123")
	require.NoError(t, err)
	assert.Equal(t, person.ID, byNamespaced.ID, "the namespaced alias resolves to the legacy page")
	assert.Subset(t, byNamespaced.Aliases, []string{"U123", "a@x.test", "1:U123"},
		"the legacy page gained the namespaced alias, keeping the old ones")

	byChannel, err := Resolve(v, d, "1:C1GEN")
	require.NoError(t, err)
	assert.Equal(t, channel.ID, byChannel.ID)

	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	assert.Len(t, nodes, 2, "no duplicate entity minted")
	assert.Equal(t, commitsBefore+1, commitCount(t, repo), "one commit for the alias stitch")
}

// TestSeedSkipsCandidateSpanningTwoNodes: the candidate's user id and e-mail
// already live on DIFFERENT pages. Unifying them is a merge — the semantic
// tier's job — so the seeder must touch neither page, create nothing, write no
// commit, and say once why it stood down.
func TestSeedSkipsCandidateSpanningTwoNodes(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	byID := legacyEntityNode("Alice", "1:U123")
	byEmail := legacyEntityNode("A. Adams", "a@x.test")
	writeAndIndex(t, v, d, byID)
	writeAndIndex(t, v, d, byEmail)
	writeAndIndex(t, v, d, legacyEntityNode("#general", "1:C1GEN"))

	seedUser(t, d, "1:U123", "Alice Adams", "a@x.test", 0)
	seedChannel(t, d, "1:C1GEN", "general", "", "")
	seedMessages(t, d, "1:C1GEN", "1:U123", 3)

	repo := openTestRepo(t, v.path)
	commitsBefore := commitCount(t, repo)

	var logs []string
	created, err := SeedEntities(v, d, seedTestConfig, func(format string, args ...any) {
		logs = append(logs, fmt.Sprintf(format, args...))
	})
	require.NoError(t, err)
	assert.Zero(t, created, "a spanning candidate is never seeded")

	require.Len(t, logs, 1, "exactly one line about the spanning candidate")
	assert.Contains(t, logs[0], "spans nodes")
	assert.Contains(t, logs[0], byID.ID)
	assert.Contains(t, logs[0], byEmail.ID)

	assert.Equal(t, commitsBefore, commitCount(t, repo), "nothing written")
	for _, n := range []Node{byID, byEmail} {
		got, err := Resolve(v, d, n.ID)
		require.NoError(t, err)
		assert.Equal(t, n.Aliases, got.Aliases, "page %s left untouched", n.ID)
	}
	nodes, err := d.ListMemoryNodes()
	require.NoError(t, err)
	assert.Len(t, nodes, 3, "no fourth page minted")
}

// TestSeedAliasArrangementsNeverCollide walks the alias arrangements a live
// vault can be in after the multi-account migrations — bare page vs namespaced
// candidate and back, partial overlaps, case differences, a split identity —
// and pins that none of them makes the seeder return a UNIQUE-constraint error
// (the audit C2 failure mode is impossible by construction, not merely
// unobserved). The person is always the same human: user "1:U123", e-mail
// "a@x.test".
func TestSeedAliasArrangementsNeverCollide(t *testing.T) {
	cases := []struct {
		name        string
		pages       [][]string // aliases of the entity pages already in the vault
		wantCreated int
		wantStitch  []string // aliases the person's page must carry afterwards
	}{
		{
			name:        "legacy bare page gains the namespaced alias",
			pages:       [][]string{{"U123", "a@x.test"}},
			wantCreated: 0,
			wantStitch:  []string{"U123", "a@x.test", "1:U123"},
		},
		{
			name:        "namespaced page already complete",
			pages:       [][]string{{"1:U123", "a@x.test"}},
			wantCreated: 0,
			wantStitch:  []string{"1:U123", "a@x.test"},
		},
		{
			name:        "page keyed by e-mail alone gains the user id",
			pages:       [][]string{{"a@x.test"}},
			wantCreated: 0,
			wantStitch:  []string{"a@x.test", "1:U123"},
		},
		{
			name:        "page keyed by user id alone gains the e-mail",
			pages:       [][]string{{"1:U123"}},
			wantCreated: 0,
			wantStitch:  []string{"1:U123", "a@x.test"},
		},
		{
			name:        "case-differing e-mail is not appended twice",
			pages:       [][]string{{"U123", "A@X.TEST"}},
			wantCreated: 0,
			wantStitch:  []string{"U123", "A@X.TEST", "1:U123"},
		},
		{
			name:        "no page at all — an ordinary create",
			pages:       nil,
			wantCreated: 1,
			wantStitch:  []string{"1:U123", "a@x.test"},
		},
		{
			name:        "identity split across two pages — neither is touched",
			pages:       [][]string{{"1:U123"}, {"a@x.test"}},
			wantCreated: 0,
			wantStitch:  []string{"1:U123"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			v, d := newTestVault(t), newTestDB(t)
			// The channel page always exists, so the counts below describe the
			// person alone.
			writeAndIndex(t, v, d, legacyEntityNode("#general", "1:C1GEN"))
			for i, aliases := range tc.pages {
				writeAndIndex(t, v, d, legacyEntityNode(fmt.Sprintf("Page %d", i), aliases...))
			}
			seedUser(t, d, "1:U123", "Alice Adams", "a@x.test", 0)
			seedChannel(t, d, "1:C1GEN", "general", "", "")
			seedMessages(t, d, "1:C1GEN", "1:U123", 3)

			created, err := SeedEntities(v, d, seedTestConfig, nil)
			require.NoError(t, err, "no alias arrangement may collide on memory_aliases")
			assert.Equal(t, tc.wantCreated, created)

			n, err := Resolve(v, d, tc.wantStitch[0])
			require.NoError(t, err)
			assert.Equal(t, tc.wantStitch, n.Aliases)

			nodes, err := d.ListMemoryNodes()
			require.NoError(t, err)
			assert.Len(t, nodes, 1+len(tc.pages)+tc.wantCreated, "page count")
		})
	}
}

// TestSeedStitchDoesNotAbortPipelineRun: the live symptom of the C2 crash was
// that seeding (step 2) returned an error, so no later step of the memory run
// ever executed. Over the same legacy-alias arrangement the whole run must now
// complete.
func TestSeedStitchDoesNotAbortPipelineRun(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, legacyEntityNode("Alice Adams", "U123", "a@x.test"))
	seedUser(t, d, "1:U123", "Alice Adams", "a@x.test", 0)
	seedChannel(t, d, "1:C1GEN", "general", "", "")
	seedMessages(t, d, "1:C1GEN", "1:U123", 3)

	gen := &fakeGen{reply: func(string) (string, error) { return "[]", nil }}
	stats, err := NewPipeline(d, v, gen, pipelineTestConfig(), t.Logf).Run(context.Background())
	require.NoError(t, err, "a stitched candidate must not abort the run")
	assert.Equal(t, 1, stats.Seeded, "the channel is created; the person is stitched, not counted")
}
