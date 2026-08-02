package inbox

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// recentTS returns a Slack-style timestamp string relative to now.
func recentTS(minutesAgo int) string {
	t := time.Now().Add(-time.Duration(minutesAgo) * time.Minute)
	return fmt.Sprintf("%d.000100", t.Unix())
}

type mockGenerator struct {
	response string
}

func (m *mockGenerator) Generate(_ context.Context, _, _, _ string) (string, *digest.Usage, string, error) {
	return m.response, &digest.Usage{InputTokens: 100, OutputTokens: 50, CostUSD: 0}, "mock-session", nil
}

func testDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func testConfig() *config.Config {
	return &config.Config{
		Digest: config.DigestConfig{
			Enabled: true,
		},
		Inbox: config.InboxConfig{
			Enabled:             true,
			MaxItemsPerRun:      100,
			InitialLookbackDays: 7,
			MaxTriageMessages:   config.DefaultInboxMaxTriageMessages,
			MaxAwarenessCards:   config.DefaultInboxMaxAwarenessCards,
		},
		Dashboard: config.DashboardConfig{
			StaleAfterDays:    config.DefaultDashboardStaleAfterDays,
			MaxComposeSignals: config.DefaultDashboardMaxComposeSignals,
		},
	}
}

// seedWorkspaceAndUser inserts a workspace and sets the current user.
func seedWorkspaceAndUser(t *testing.T, database *db.DB, userID string) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO workspace (id, name, current_user_id) VALUES ('T1', 'Test', ?)`, userID)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO users (id, name) VALUES (?, 'testuser')`, userID)
	require.NoError(t, err)
}

func TestPipeline_Run_NoUser(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()
	p := New(database, cfg, nil, log.Default())

	created, resolved, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, created)
	assert.Equal(t, 0, resolved)
}

func TestPipeline_Run_DetectMentions(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts := recentTS(30) // 30 minutes ago
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES ('C1', ?, 'U_OTHER', 'Hey <@U_ME> review please', 'https://slack.com/p1')`, ts)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "mention", items[0].TriggerType)
	assert.Equal(t, "pending", items[0].Status)
}

func TestPipeline_Run_DetectDMs(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts := recentTS(30)
	_, err := database.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('D1', 'dm-other', 'dm', 'U_OTHER')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('D1', ?, 'U_OTHER', 'Hey, got a minute?')`, ts)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "dm", items[0].TriggerType)
}

func TestInbox02_AutoResolveSlackOnUserReply(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// User replies in Slack → mention/dm/thread_reply auto-resolves.
	// Do not weaken or remove without explicit owner approval.
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts1 := recentTS(30)
	ts2 := recentTS(20) // reply 10 minutes later
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U_OTHER', 'Hey <@U_ME> check this')`, ts1)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U_ME', 'Done!')`, ts2)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, resolved, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)
	assert.Equal(t, 1, resolved)

	items, err := database.GetInboxItems(db.InboxFilter{IncludeResolved: true})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "resolved", items[0].Status)
}

func TestPipeline_Run_NoDuplicates(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts := recentTS(30)
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U_OTHER', 'Hey <@U_ME> check this')`, ts)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())

	created1, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created1)

	// Second run — should not create duplicates (FindPendingMentions has NOT EXISTS)
	created2, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, created2)
}

func TestPipeline_Run_WithAI(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts := recentTS(30)
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U_OTHER', 'Hey <@U_ME> urgent blocker')`, ts)
	require.NoError(t, err)

	gen := &mockGenerator{
		response: `{"verdicts": [{"key": "item:1", "tier": "action", "priority": "high", "reason": "Production blocker from team lead"}]}`,
	}

	p := New(database, cfg, gen, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "high", items[0].Priority)
	assert.Equal(t, "Production blocker from team lead", items[0].AIReason)
}

func TestPipeline_LastProcessedTS(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	p := New(database, cfg, nil, log.Default())
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	ts, err := database.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Greater(t, ts, float64(0))
}

func TestIsClosingSignal(t *testing.T) {
	tests := []struct {
		text string
		want bool
	}{
		// English
		{"thanks", true},
		{"Thank you", true},
		{"Thanks!", true},
		{"Thanks!!", true},
		{"thx", true},
		{"ty", true},
		{"got it", true},
		{"ok", true},
		{"Ok.", true},
		{"okay", true},
		{"cool", true},
		{"great", true},
		{"perfect", true},
		{"awesome", true},
		{"np", true},
		{"no problem", true},
		{"will do", true},
		{"sounds good", true},
		{"noted", true},
		{"ack", true},
		// Russian
		{"спасибо", true},
		{"Спасибо!", true},
		{"спс", true},
		{"ок", true},
		{"понял", true},
		{"понятно", true},
		{"принял", true},
		{"ясно", true},
		{"хорошо", true},
		{"отлично", true},
		{"ладно", true},
		{"круто", true},
		{"пон", true},
		// Emoji
		{"👍", true},
		{"🙏", true},
		{"🙌", true},
		{"👌", true},
		{"✅", true},
		// Whitespace/punctuation variations
		{" thanks ", true},
		{"Thanks...", true},
		{"Ok,", true},
		// NOT closing signals
		{"thanks but also need the API docs updated", false},
		{"ok can you also check the other PR", false},
		{"", false},
		{"Can you review this?", false},
		{"I need help with deployment", false},
		// Too long (>80 chars)
		{"thanks for looking into this and also please check the other thing that I mentioned earlier in the thread about the deployment", false},
	}

	for _, tt := range tests {
		t.Run(tt.text, func(t *testing.T) {
			assert.Equal(t, tt.want, isClosingSignal(tt.text), "isClosingSignal(%q)", tt.text)
		})
	}
}

func TestPipeline_ClosingSignalSkipped(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)

	// User replied first, then other person says "спасибо".
	ts1 := recentTS(30)
	ts2 := recentTS(20)
	ts3 := recentTS(10) // "спасибо"

	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', ?, 'U_OTHER', 'Hey <@U_ME> can you check?', ?)`, ts1, ts1)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', ?, 'U_ME', 'Done!', ?)`, ts2, ts1)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', ?, 'U_OTHER', 'Спасибо!', ?)`, ts3, ts1)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)

	// The "спасибо" should be skipped (closing signal + user replied before).
	// The original mention should be auto-resolved (user replied after).
	items, err := database.GetInboxItems(db.InboxFilter{IncludeResolved: true})
	require.NoError(t, err)

	// Only the original mention should have been created, not the "спасибо".
	for _, item := range items {
		assert.NotContains(t, item.Snippet, "Спасибо", "closing signal should not create an inbox item")
	}
}

func TestPipeline_ClosingSignalNoUserReply(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	_, err := database.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('D1', 'dm-other', 'dm', 'U_OTHER')`)
	require.NoError(t, err)

	// Other person says "thanks" but user NEVER replied — should still create item (safety).
	ts1 := recentTS(30)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('D1', ?, 'U_OTHER', 'thanks')`, ts1)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created, "closing signal without prior user reply should create item")
}

func TestPipeline_Run_OrderedPhases(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "alice")

	// Seed: a jira issue assigned to alice, a calendar invite for alice, a high-importance digest decision.
	seedJiraIssue(t, d, "WT-1", "alice", time.Now().Add(-5*time.Minute))
	seedCalendarEvent(t, d, "evt-1", "Sync", `[{"email":"alice@x.com","rsvp_status":"needsAction"}]`, "confirmed",
		time.Now().Add(-10*time.Minute), time.Now().Add(-10*time.Minute))
	seedDigestWithHighImportance(t, d, "C1", `[{"type":"decision","topic":"Launch","importance":"high"}]`,
		time.Now().Add(-5*time.Minute))

	cfg := testConfig()
	gen := &mockGenerator{response: `{}`}
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("alice", "alice@x.com")

	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	mustCount := func(trig string, want int) {
		t.Helper()
		var n int
		d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type=?`, trig).Scan(&n) //nolint:errcheck
		assert.Equal(t, want, n, "trigger_type=%s", trig)
	}
	mustCount("jira_assigned", 1)
	mustCount("calendar_invite", 1)
	mustCount("decision_made", 1)

	// decision_made should be classified as ambient
	var cls string
	d.QueryRow(`SELECT item_class FROM inbox_items WHERE trigger_type='decision_made'`).Scan(&cls) //nolint:errcheck
	assert.Equal(t, "ambient", cls, "decision_made item_class")
}

func TestPipeline_Run_AutoArchiveRuns(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	// Insert an 8-days-old ambient decision_made item.
	oldT := time.Now().Add(-8 * 24 * time.Hour).UTC().Format(time.RFC3339)
	_, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, item_class, created_at, updated_at)
		VALUES ('C1','1.0','U1','decision_made','pending','low','ambient',?,?)`, oldT, oldT)
	require.NoError(t, err)

	p := New(d, testConfig(), &mockGenerator{response: `{}`}, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)

	var reason string
	d.QueryRow(`SELECT archive_reason FROM inbox_items WHERE trigger_type='decision_made'`).Scan(&reason) //nolint:errcheck
	assert.Equal(t, "seen_expired", reason)
}

// TestPipeline_AIResolvedField verifies that a triage "awareness" verdict on
// an actionable trigger item demotes it to ambient (INBOX-01), the new
// analogue of the old AI-resolve mechanic: an item like a closing-signal
// mention no longer needs to be resolved outright, just deprioritized —
// only a rule-based auto-resolve (see autoResolveByRules) can close it.
func TestPipeline_AIResolvedField(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts := recentTS(30)
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', ?, 'U_OTHER', 'Hey <@U_ME> thanks for fixing that')`, ts)
	require.NoError(t, err)

	gen := &mockGenerator{
		response: `{"verdicts": [{"key": "item:1", "tier": "awareness", "priority": "low", "reason": "Closing signal — no reply needed"}]}`,
	}

	p := New(database, cfg, gen, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "pending", items[0].Status)
	assert.Equal(t, "ambient", items[0].ItemClass, "triage awareness verdict should demote an actionable trigger item")
	assert.Equal(t, "Closing signal — no reply needed", items[0].AIReason)
}

// newPipelineForTest creates a Pipeline with the given user identity pre-set.
func newPipelineForTest(t *testing.T, d *db.DB, userID, email string) *Pipeline {
	t.Helper()
	seedWorkspaceAndUser(t, d, userID)
	cfg := testConfig()
	p := New(d, cfg, &mockGenerator{response: `{}`}, log.Default())
	p.SetCurrentUser(userID, email)
	return p
}

// seedJiraComment creates the jira_comments table (if absent) and inserts a row.
func seedJiraComment(t *testing.T, d *db.DB, issueKey, authorID, body string, createdAt time.Time) {
	t.Helper()
	_, err := d.Exec(`CREATE TABLE IF NOT EXISTS jira_comments (
		id          TEXT PRIMARY KEY,
		issue_key   TEXT NOT NULL,
		author_id   TEXT NOT NULL,
		body        TEXT NOT NULL DEFAULT '',
		created_at  TEXT NOT NULL,
		updated_at  TEXT NOT NULL
	)`)
	require.NoError(t, err, "create jira_comments table")
	ts := createdAt.UTC().Format(time.RFC3339)
	_, err = d.Exec(`INSERT INTO jira_comments (id, issue_key, author_id, body, created_at, updated_at)
		VALUES (?,?,?,?,?,?)`,
		fmt.Sprintf("%s-%s-%d", issueKey, authorID, createdAt.UnixNano()),
		issueKey, authorID, body, ts, ts)
	require.NoError(t, err, "insert jira_comment")
}

func TestInbox02_AutoResolveJiraOnUserComment(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// User comments on a Jira issue → jira_comment_mention auto-resolves.
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	// Open jira_comment_mention for WT-1, then user adds comment to the issue.
	seedJiraIssue(t, d, "WT-1", "alice", time.Now().Add(-1*time.Hour))
	seedJiraComment(t, d, "WT-1", "bob", "hey [~alice]", time.Now().Add(-30*time.Minute))
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	// Now alice comments — seed her comment and run again.
	seedJiraComment(t, d, "WT-1", "alice", "got it", time.Now())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	var status string
	d.QueryRow(`SELECT status FROM inbox_items WHERE trigger_type='jira_comment_mention' AND channel_id='WT-1'`).Scan(&status) //nolint:errcheck
	if status != "resolved" {
		t.Errorf("want resolved, got %q", status)
	}
}

func TestInbox02_AutoResolveCalendarOnUserRSVP(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// User responds to a calendar invite → calendar_invite auto-resolves.
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedCalendarEvent(t, d, "evt-1", "Sync",
		`[{"email":"alice@x.com","rsvp_status":"needsAction"}]`,
		"confirmed",
		time.Now().Add(-30*time.Minute), time.Now().Add(-30*time.Minute))
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	// Now alice responds — update attendees RSVP and run again.
	_, err = d.Exec(`UPDATE calendar_events SET attendees=? WHERE id='evt-1'`,
		`[{"email":"alice@x.com","rsvp_status":"accepted"}]`)
	require.NoError(t, err)
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	var status string
	d.QueryRow(`SELECT status FROM inbox_items WHERE trigger_type='calendar_invite'`).Scan(&status) //nolint:errcheck
	if status != "resolved" {
		t.Errorf("want resolved, got %q", status)
	}
}

// TestPipeline_RunFastDetection verifies that RunFastDetection picks up Slack
// DMs immediately, leaves the watermark untouched, and skips decision_made
// detection (which depends on digests written later in the daemon cycle).
func TestPipeline_RunFastDetection(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "alice")

	// A Slack DM addressed to alice — should be picked up by fast detection.
	dmTS := recentTS(20)
	_, err := d.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('D1', 'dm-bob', 'dm', 'U_BOB')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('D1', ?, 'U_BOB', 'привет, есть минутка?')`, dmTS)
	require.NoError(t, err)

	// A digest with a high-importance decision — should NOT be picked up by fast
	// detection (DetectWatchtowerInternal is skipped); the full Run picks it up.
	seedDigestWithHighImportance(t, d, "C1",
		`[{"type":"decision","topic":"Migrate to v2","importance":"high"}]`,
		time.Now().Add(-5*time.Minute))

	cfg := testConfig()
	p := New(d, cfg, nil, log.Default())
	p.SetCurrentUser("alice", "alice@x.com")

	wmBefore, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)

	require.NoError(t, p.RunFastDetection(context.Background()))

	dmCount := func() int {
		var n int
		d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type='dm'`).Scan(&n) //nolint:errcheck
		return n
	}
	decisionCount := func() int {
		var n int
		d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type='decision_made'`).Scan(&n) //nolint:errcheck
		return n
	}

	assert.Equal(t, 1, dmCount(), "DM should be detected by fast pass")
	assert.Equal(t, 0, decisionCount(), "decision_made must NOT be detected by fast pass")

	wmAfter, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, wmBefore, wmAfter, "RunFastDetection must not advance the watermark")

	// Subsequent full Run must pick up the digest decision and advance the watermark.
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, dmCount(), "full Run must not duplicate the DM detected by fast pass")
	assert.Equal(t, 1, decisionCount(), "full Run must detect decision_made from the digest")

	wmAfterFull, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Greater(t, wmAfterFull, wmBefore, "full Run must advance the watermark")
}

// TestPipeline_RunFastDetection_DisabledConfigNoOp: with inbox.enabled=false
// the fast pass is a clean no-op — no detection, no writes.
func TestPipeline_RunFastDetection_DisabledConfigNoOp(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "alice")

	// A DM that WOULD be detected if the pipeline were enabled.
	_, err := d.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('D1', 'dm-bob', 'dm', 'U_BOB')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('D1', ?, 'U_BOB', 'ping')`, recentTS(10))
	require.NoError(t, err)

	cfg := testConfig()
	cfg.Inbox.Enabled = false
	p := New(d, cfg, nil, log.Default())
	p.SetCurrentUser("alice", "alice@x.com")

	require.NoError(t, p.RunFastDetection(context.Background()))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items`).Scan(&n))
	assert.Equal(t, 0, n, "disabled pipeline must write nothing")
}

// TestPipeline_RunFastDetection_NoCurrentUserCleanExit: a workspace with no
// current user (valid but degenerate — e.g. before the first auth.test) exits
// cleanly with zero writes instead of erroring or mis-detecting.
func TestPipeline_RunFastDetection_NoCurrentUserCleanExit(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "") // workspace row exists, current_user_id empty

	_, err := d.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('D1', 'dm-bob', 'dm', 'U_BOB')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('D1', ?, 'U_BOB', 'ping')`, recentTS(10))
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())

	require.NoError(t, p.RunFastDetection(context.Background()))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items`).Scan(&n))
	assert.Equal(t, 0, n, "no-current-user fast pass must write nothing")
}

// TestRunFastDetectionPicksUpGmail: a Gmail message addressed to the current
// user's email should surface as an email_received inbox item via the fast
// detection pass, same as Slack/Jira/Calendar sources.
func TestRunFastDetectionPicksUpGmail(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	acctID, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "me@x.com", Label: "Me", GmailEnabled: true})
	require.NoError(t, err)

	require.NoError(t, d.UpsertGmailMessage(acctID, db.GmailMessage{
		ID:           "g1",
		ThreadID:     "th1",
		FromEmail:    "a@x.com",
		Subject:      "Ping",
		ToJSON:       `["me@x.com"]`,
		CcJSON:       `[]`,
		InternalDate: "2026-07-09T09:00:00Z",
		SyncedAt:     time.Now().UTC().Format(time.RFC3339),
	}))

	p := New(d, testConfig(), nil, log.Default())
	p.SetCurrentUser("U1", "me@x.com")

	require.NoError(t, p.RunFastDetection(context.Background()))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type='email_received'`).Scan(&n))
	assert.Equal(t, 1, n, "want 1 email inbox item")
}

// TestInbox09_WatermarkFrozenOnDetectorError guards INBOX-09: when a detector
// pass fails, the inbox watermark must NOT advance. Advancing it on failure
// permanently skips the window of mentions/DMs the failed pass never scanned.
// A broken detector is simulated by removing the table DetectJira reads.
func TestInbox09_WatermarkFrozenOnDetectorError(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U_ME")

	// Freeze the watermark at a known, non-zero value.
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	// Break one detector: DetectJira queries jira_issues, so dropping it makes
	// the detector pass return an error.
	_, err := d.Exec(`DROP TABLE jira_issues`)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err, "a detector failure must not fail the whole run")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts,
		"detector failure must leave the inbox watermark untouched to avoid losing the skipped window")
}

// TestInbox09_WatermarkFrozenOnTriageError guards INBOX-09 for the triage
// stage: when runTriage itself fails (AI call/parse error), the watermark
// must NOT advance past what was never fully triaged, and Run must surface
// the error (unlike a lone detector error, which is swallowed — see
// TestInbox09_WatermarkFrozenOnDetectorError).
func TestInbox09_WatermarkFrozenOnTriageError(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	// A stream candidate (no mention/DM) so triage has something to chunk,
	// but nothing was triaged successfully before the AI call fails.
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1100.0", "U2", "channel chatter after the watermark")

	cfg := testConfig()
	gen := &seqGenerator{responses: []string{""}} // triage AI call errors
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")

	_, _, err := p.Run(context.Background())
	require.Error(t, err, "a triage failure must be surfaced, unlike a detector-only failure")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts,
		"triage failure with no progress must leave the inbox watermark untouched")
}

// TestInbox09_DetectorErrorFreezesEvenWhenTriageCapped guards INBOX-09: a
// detector error must ALWAYS freeze the watermark, even when the capped
// stream triage succeeds. Detectors and triage scan the same ts window, so
// advancing over triage's progress would still permanently skip the
// mentions/DMs the failed detector never saw.
func TestInbox09_DetectorErrorFreezesEvenWhenTriageCapped(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	const frozen = 50.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	// Stream candidates above the watermark, more than the triage cap.
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "101.0", "U2", "first")
	insertMessage(t, d, "C1", "102.0", "U2", "second")
	insertMessage(t, d, "C1", "103.0", "U2", "third — beyond the cap")

	// Break one detector: DetectJira queries jira_issues, so dropping it makes
	// the detector pass return an error while triage still runs and caps.
	_, err := d.Exec(`DROP TABLE jira_issues`)
	require.NoError(t, err)

	cfg := testConfig()
	cfg.Inbox.MaxTriageMessages = 2 // triage caps at ts=102 and succeeds
	gen := &seqGenerator{responses: []string{`{"verdicts":[]}`}}
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")

	_, _, err = p.Run(context.Background())
	require.NoError(t, err, "a detector failure alone must not fail the whole run")
	require.Equal(t, 1, gen.calls, "triage must still have run (and capped) despite the detector error")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts,
		"a detector error must freeze the watermark even when the capped triage succeeded")
}

// TestInbox09_CappedTriageAdvancesWatermarkPartially guards INBOX-09: when
// the stream scan hits its per-cycle cap (MaxTriageMessages) but triage
// otherwise succeeds, the watermark advances only over what was actually
// scanned — not to the standard now-30min buffer, which would skip whatever
// lies beyond the cap.
func TestInbox09_CappedTriageAdvancesWatermarkPartially(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	// Seed a small non-zero watermark so Run doesn't fall back to the
	// "no prior watermark" lookback default (now-N-days), which would sit
	// far above the ts=101..103 test messages and mask the capped-advance
	// under the "never below lastTS" clamp.
	require.NoError(t, d.SetInboxLastProcessedTS(50))

	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "101.0", "U2", "first")
	insertMessage(t, d, "C1", "102.0", "U2", "second")
	insertMessage(t, d, "C1", "103.0", "U2", "third — beyond the cap")

	cfg := testConfig()
	cfg.Inbox.MaxTriageMessages = 2
	gen := &seqGenerator{responses: []string{`{"verdicts":[]}`}}
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")

	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, float64(102), ts,
		"a capped-but-successful triage must advance the watermark only over the scanned window")
}

// TestInbox07_FeedUntouchedOnTriageError guards INBOX-07: when triage fails,
// pending items already in the feed must keep their prior status, priority,
// and item_class — a failed AI call must never look like a silent decision.
func TestInbox07_FeedUntouchedOnTriageError(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")

	id := mustCreateInboxItem(t, d, db.InboxItem{
		ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention",
	})

	cfg := testConfig()
	gen := &seqGenerator{responses: []string{"", ""}} // triage call, then a possible compose call — both error
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")

	_, _, err := p.Run(context.Background())
	require.Error(t, err)

	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	assert.Equal(t, "pending", it.Status, "status must be untouched on triage error")
	assert.Equal(t, "medium", it.Priority, "priority must be untouched on triage error")
	assert.Equal(t, "actionable", it.ItemClass, "item_class must be untouched on triage error")
}

// triageKeyRegexp matches the "key=<candidate-key>" token emitted on every
// triage candidate line (see triage.go's line formats for trigger items and
// stream messages).
var triageKeyRegexp = regexp.MustCompile(`key=(\S+)`)

// keyEchoGenerator is a stub AI generator that records every prompt it sees
// and, for triage calls, echoes back a low-priority "awareness" verdict for
// each candidate key actually present in the prompt — mirroring how a real
// model can only judge what it was shown. Non-triage prompts (e.g. card
// generation) contain no "key=" tokens, so they get an empty verdict list,
// which is harmless (card parsing just fails and the item is retried later).
type keyEchoGenerator struct {
	prompts []string
}

func (g *keyEchoGenerator) Generate(_ context.Context, system, _, _ string) (string, *digest.Usage, string, error) {
	g.prompts = append(g.prompts, system)
	matches := triageKeyRegexp.FindAllStringSubmatch(system, -1)
	verdicts := make([]string, 0, len(matches))
	for _, m := range matches {
		verdicts = append(verdicts, fmt.Sprintf(`{"key":%q,"tier":"awareness","priority":"low","reason":"recent"}`, m[1]))
	}
	return fmt.Sprintf(`{"verdicts":[%s]}`, strings.Join(verdicts, ",")), &digest.Usage{}, "", nil
}

// TestTriage_FreshWatermarkUsesLookbackFloor guards the first-run path: Run
// floors a fresh/zero watermark to now-InitialLookbackDays before calling
// into triage (see docs/inventory/inbox-pulse.md). Before the fix, runTriage
// re-read the raw (zero) watermark internally, so a fresh install's first
// cycle scanned the entire backfilled message history — this test seeds one
// message far outside the lookback window and one inside it, and asserts the
// triage prompt only ever contains the recent one.
func TestTriage_FreshWatermarkUsesLookbackFloor(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "U1")
	insertChannel(t, d, "C1", "public")

	oldTS := fmt.Sprintf("%d.000100", time.Now().AddDate(0, 0, -30).Unix())
	newTS := recentTS(60)
	insertMessage(t, d, "C1", oldTS, "U2", "ancient channel chatter well before the lookback window")
	insertMessage(t, d, "C1", newTS, "U2", "recent channel chatter needs a look")

	cfg := testConfig() // InitialLookbackDays: 7
	gen := &keyEchoGenerator{}
	p := New(d, cfg, gen, log.Default())
	p.SetCurrentUser("U1", "u1@test.com")

	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	var triagePrompt string
	found := false
	for _, pr := range gen.prompts {
		if strings.Contains(pr, "=== CANDIDATES ===") {
			require.False(t, found, "expected exactly one triage call for this small fixture")
			triagePrompt = pr
			found = true
		}
	}
	require.True(t, found, "expected a triage call")
	assert.Contains(t, triagePrompt, "recent channel chatter needs a look",
		"the recent message must be inside the lookback-floored triage window")
	assert.NotContains(t, triagePrompt, "ancient channel chatter",
		"a fresh watermark must be floored to now-lookbackDays, not scan the entire backfilled history")

	// The recent message should have been created as a stream item; the
	// ancient one was never even offered to the AI, so it can't exist.
	recentItem, _ := d.GetInboxItemByMessage("C1", newTS)
	assert.NotNil(t, recentItem, "recent stream message should become an inbox item")
	oldItem, _ := d.GetInboxItemByMessage("C1", oldTS)
	assert.Nil(t, oldItem, "ancient stream message outside the lookback window must not become an inbox item")
}
