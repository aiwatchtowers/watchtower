package inbox

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

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
			InitialLookbackDays: 7,
		},
	}
}

// seedWorkspaceAndUser inserts a workspace and sets the current user (now
// slack_accounts account #1's current_user_id — see internal/db/slack_accounts.go).
func seedWorkspaceAndUser(t *testing.T, database *db.DB, userID string) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`)
	require.NoError(t, err)
	_, err = database.CreateSlackAccount(db.SlackAccount{CurrentUserID: userID})
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
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES ('1:C1', ?, 'U_OTHER', 'Hey <@U_ME> review please', 'https://slack.com/p1')`, ts)
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
	_, err := database.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('1:D1', 'dm-other', 'dm', 'U_OTHER')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:D1', ?, 'U_OTHER', 'Hey, got a minute?')`, ts)
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

// TestPipeline_Run_DetectMentionsAcrossAccounts guards the multi-account
// Slack detection loop: with two enabled Slack accounts, a mention of each
// account's own user in that account's own channel must both surface in one
// Run. Before the per-account loop, detectSlackTriggers was hardcoded to
// account 1, so account 2's mention was silently invisible.
func TestPipeline_Run_DetectMentionsAcrossAccounts(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "1:U_ME1")
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "2:U_ME2"})
	require.NoError(t, err)

	ts := recentTS(30)
	_, err = database.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> review please')`, ts)
	require.NoError(t, err)

	_, err = database.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U_OTHER', 'Hey <@U_ME2> review please')`, ts)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 2, created, "both accounts' mentions must be detected in one Run")

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 2)
	gotChannels := map[string]bool{}
	for _, item := range items {
		gotChannels[item.ChannelID] = true
	}
	assert.True(t, gotChannels["1:C1"], "account 1's mention must be detected")
	assert.True(t, gotChannels["2:C1"], "account 2's mention must be detected")
}

// TestPipeline_Run_PerAccountOwnMessageExclusion guards against hoisting a
// single current_user_id out of the per-account Slack loop: own-message
// exclusion must use EACH account's own current_user_id (read from that
// account's own slack_accounts row), never one identity reused across every
// account. If current_user_id were resolved once outside the loop — e.g.
// from the install's single owner (db.ResolveOwner), which is at most
// account #1's user by design — account 2's own outgoing DM and
// self-mention would stop being excluded and arrive as false "needs
// attention" items, while a genuine message from someone else in account 2
// must still be detected. Each case lives in its own channel so the
// (channel, thread) grouping in detectSlackTriggers can't merge a wrongly
// -included own message into the genuine item and hide the regression
// behind a coincidentally correct created count.
func TestPipeline_Run_PerAccountOwnMessageExclusion(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "1:U_ME1")
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "2:U_ME2"})
	require.NoError(t, err)

	// Account 2's own outgoing DM — must be excluded by account 2's own identity.
	_, err = database.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('2:D1', 'dm-other', 'dm', '2:U_OTHER')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:D1', ?, '2:U_ME2', 'sure, will do')`, recentTS(30))
	require.NoError(t, err)

	// Account 2's own self-mention — must also be excluded.
	_, err = database.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C2', 'notes', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C2', ?, '2:U_ME2', 'note to self <@U_ME2>')`, recentTS(29))
	require.NoError(t, err)

	// A genuine message from someone else in account 2 must still be detected.
	_, err = database.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U_OTHER', 'Hey <@U_ME2> real question')`, recentTS(28))
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created, "only the message from someone else should create an item")

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "2:C1", items[0].ChannelID, "the created item must be the genuine one, not a leaked own-message")
	assert.Equal(t, "2:U_OTHER", items[0].SenderUserID)
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
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, 'U_OTHER', 'Hey <@U_ME> check this')`, ts1)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, 'U_ME', 'Done!')`, ts2)
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

// TestInbox02_AutoResolveSlackAccount2OnOwnerReply guards INBOX-02 for a
// second connected Slack account: an item created for account 2 must
// resolve when ACCOUNT 2's OWN owner replies, and must NOT resolve when
// someone else in the same account replies. Pins the fix that scopes
// autoResolveSlack to each item's own account (derived from its
// channel_id prefix) instead of checking every pending item against the
// single account-#1 identity.
func TestInbox02_AutoResolveSlackAccount2OnOwnerReply(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "1:U_ME1")
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "2:U_ME2"})
	require.NoError(t, err)

	_, err = database.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U_OTHER', 'Hey <@U_ME2> check this')`, recentTS(30))
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	require.Equal(t, 1, created)

	// Someone else in account 2 replies — must NOT resolve the item.
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U_THIRD', 'me too, interested')`, recentTS(25))
	require.NoError(t, err)
	_, resolvedByOther, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, resolvedByOther, "a reply from someone other than account 2's own owner must not resolve the item")

	items, err := database.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "pending", items[0].Status)

	// Account 2's OWN owner replies — must resolve the item.
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U_ME2', 'Done!')`, recentTS(20))
	require.NoError(t, err)
	_, resolvedByOwner, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, resolvedByOwner, "account 2's own owner replying must resolve the item")

	items, err = database.GetInboxItems(db.InboxFilter{IncludeResolved: true})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "resolved", items[0].Status)
}

func TestPipeline_Run_NoDuplicates(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	ts := recentTS(30)
	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, 'U_OTHER', 'Hey <@U_ME> check this')`, ts)
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

// TestTruncateRunes_MultibyteBoundary is the D5 regression: byte-slicing a
// UTF-8 string at a fixed offset (s[:n]) can land inside a multibyte rune and
// produce invalid UTF-8. truncateRunes must cut on rune boundaries instead.
func TestTruncateRunes_MultibyteBoundary(t *testing.T) {
	// Each "я" is 2 bytes in UTF-8, so a byte-offset cut at an odd byte count
	// would split one in half; a rune-based cut never does.
	text := strings.Repeat("я", 600)

	got := truncateRunes(text, 500)

	if !utf8.ValidString(got) {
		t.Fatalf("truncateRunes produced invalid UTF-8: %q", got)
	}
	want := strings.Repeat("я", 500) + "..."
	if got != want {
		t.Fatalf("truncateRunes(600 runes, 500) = %q, want %q", got, want)
	}
}

func TestTruncateRunes_ShortStringUnchanged(t *testing.T) {
	if got := truncateRunes("short", 500); got != "short" {
		t.Fatalf("truncateRunes(short) = %q, want unchanged", got)
	}
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

// TestPipeline_ClosingSignalSkipped guards the closing-signal pre-filter: a
// "thanks"-only reply after the user already answered must not spawn its own
// inbox item.
//
// KNOWN LIMITATION (confirmed pre-existing and unrelated to account-scoping —
// present identically at this branch's fork point, commit 2e6df15b, before
// any change in this branch): detectSlackTriggers groups Slack candidates by
// (channel, thread) and runs the closing-signal check only against the
// group's LATEST message by timestamp. Because "Спасибо!" lands in the SAME
// thread as the original mention and is chronologically last, the whole
// group — including the substantive original mention — is suppressed, not
// just the closing signal. So today NO item is created here at all, rather
// than the mention being created and then auto-resolved (the simpler
// no-closing-signal case TestInbox02_AutoResolveSlackOnUserReply pins).
// Whether "silently drop" or "create then auto-resolve" is the right product
// behavior is an open question flagged for the owner — this test pins only
// the CURRENT behavior and must not be read as endorsing it as correct.
func TestPipeline_ClosingSignalSkipped(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	_, err := database.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)

	// User replied first, then other person says "спасибо".
	ts1 := recentTS(30)
	ts2 := recentTS(20)
	ts3 := recentTS(10) // "спасибо"

	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', ?, 'U_OTHER', 'Hey <@U_ME> can you check?', ?)`, ts1, ts1)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', ?, 'U_ME', 'Done!', ?)`, ts2, ts1)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', ?, 'U_OTHER', 'Спасибо!', ?)`, ts3, ts1)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)

	// See the KNOWN LIMITATION note above: the closing signal's thread-merge
	// suppresses the whole group, not just the closing signal itself.
	assert.Equal(t, 0, created, "current behavior: the thread-merge with the closing signal suppresses the whole group")

	items, err := database.GetInboxItems(db.InboxFilter{IncludeResolved: true})
	require.NoError(t, err)
	assert.Empty(t, items, "no item — including one carrying the closing signal's text — should exist")
}

func TestPipeline_ClosingSignalNoUserReply(t *testing.T) {
	database := testDB(t)
	cfg := testConfig()

	seedWorkspaceAndUser(t, database, "U_ME")

	_, err := database.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('1:D1', 'dm-other', 'dm', 'U_OTHER')`)
	require.NoError(t, err)

	// Other person says "thanks" but user NEVER replied — should still create item (safety).
	ts1 := recentTS(30)
	_, err = database.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:D1', ?, 'U_OTHER', 'thanks')`, ts1)
	require.NoError(t, err)

	p := New(database, cfg, nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created, "closing signal without prior user reply should create item")
}

func TestPipeline_Run_OrderedPhases(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "alice")

	// Seed: a jira issue assigned to alice, a calendar invite for alice, a briefing.
	seedJiraIssue(t, d, "WT-1", "alice", time.Now().Add(-5*time.Minute))
	seedCalendarEvent(t, d, "evt-1", "Sync", `[{"email":"alice@x.com","response_status":"needsAction"}]`, "confirmed",
		time.Now().Add(-10*time.Minute), time.Now().Add(-10*time.Minute))
	seedBriefing(t, d, "alice", time.Now().Format("2006-01-02"), time.Now().Add(-5*time.Minute))

	p := New(d, testConfig(), nil, log.Default())
	p.SetOwner(db.Owner{ID: "alice", SlackUserID: "alice", Email: "alice@x.com"})

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
	mustCount("briefing_ready", 1)

	// briefing_ready should be classified as ambient
	var cls string
	d.QueryRow(`SELECT item_class FROM inbox_items WHERE trigger_type='briefing_ready'`).Scan(&cls) //nolint:errcheck
	assert.Equal(t, "ambient", cls, "briefing_ready item_class")
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
	p.SetOwner(db.Owner{ID: "U1", SlackUserID: "U1", Email: "u1@test.com"})
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)

	var reason string
	d.QueryRow(`SELECT archive_reason FROM inbox_items WHERE trigger_type='decision_made'`).Scan(&reason) //nolint:errcheck
	assert.Equal(t, "seen_expired", reason)
}

// newPipelineForTest creates a Pipeline with the given user identity pre-set.
func newPipelineForTest(t *testing.T, d *db.DB, userID, email string) *Pipeline {
	t.Helper()
	seedWorkspaceAndUser(t, d, userID)
	cfg := testConfig()
	p := New(d, cfg, &mockGenerator{response: `{}`}, log.Default())
	p.SetOwner(db.Owner{ID: userID, SlackUserID: userID, Email: email})
	return p
}

// seedJiraComment inserts a row into the real jira_comments table (migration
// 00050; account_id=1, seeding a default test Jira account if none exists
// yet). authorAccountID is stored as BOTH the display name and the
// Atlassian account id (jira_comments.author_account_id) — tests don't care
// about a distinct display name, and it's the account id that a [~mention]
// and autoResolveJira's identity match actually key off.
//
// created_at/updated_at are written in the stored UTC form (db.FormatJiraTime),
// exactly as the real comment sync writes them — the detector's window bound
// is a plain SQL string compare against this column, so a fixture in another
// format would compare differently from production and hide a real format
// mismatch.
func seedJiraComment(t *testing.T, d *db.DB, issueKey, authorAccountID, body string, createdAt time.Time) {
	t.Helper()
	var accounts int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM jira_accounts`).Scan(&accounts))
	if accounts == 0 {
		db.SeedTestJiraAccount(t, d)
	}
	ts := db.FormatJiraTime(createdAt.UTC())
	_, err := d.Exec(`INSERT INTO jira_comments (account_id, issue_key, id, author, author_account_id, body_text, created_at, updated_at)
		VALUES (?,?,?,?,?,?,?,?)`,
		1, issueKey, fmt.Sprintf("%s-%s-%d", issueKey, authorAccountID, createdAt.UnixNano()),
		authorAccountID, authorAccountID, body, ts, ts)
	require.NoError(t, err, "insert jira_comment")
}

func TestInbox02_AutoResolveJiraOnUserComment(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// User comments on a Jira issue → jira_comment_mention auto-resolves.
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedJiraIssue(t, d, "WT-1", "alice", time.Now().Add(-1*time.Hour))
	// Map alice's Slack id to her Atlassian account id — the real schema's
	// [~mention] text and jira_comments.author_account_id are keyed on
	// Atlassian ids, not Slack ids (INBOX-02 reconciliation with the real
	// jira_comments shape from migration 00050).
	require.NoError(t, d.UpsertJiraUserMap(db.JiraUserMap{JiraAccountID: "alice", SlackUserID: "alice", DisplayName: "Alice"}))
	// Open jira_comment_mention for WT-1, then user adds comment to the issue.
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
		`[{"email":"alice@x.com","response_status":"needsAction"}]`,
		"confirmed",
		time.Now().Add(-30*time.Minute), time.Now().Add(-30*time.Minute))
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	// Now alice responds — update attendees RSVP and run again.
	_, err = d.Exec(`UPDATE calendar_events SET attendees=? WHERE id='evt-1'`,
		`[{"email":"alice@x.com","response_status":"accepted"}]`)
	require.NoError(t, err)
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	var status string
	d.QueryRow(`SELECT status FROM inbox_items WHERE trigger_type='calendar_invite'`).Scan(&status) //nolint:errcheck
	if status != "resolved" {
		t.Errorf("want resolved, got %q", status)
	}
}

func TestAutoResolveCalendar_OwnerEmailCaseInsensitive(t *testing.T) {
	d := newTestDB(t)
	seedCalendarEvent(t, d, "evt-1", "Sync",
		`[{"email":"alice@x.com","response_status":"needsAction"}]`,
		"confirmed",
		time.Now().Add(-30*time.Minute), time.Now().Add(-30*time.Minute))
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	// The syncer can store the attendee's address in a different case.
	_, err = d.Exec(`UPDATE calendar_events SET attendees=? WHERE id='evt-1'`,
		`[{"email":"Alice@X.com","response_status":"accepted"}]`)
	require.NoError(t, err)
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	var status string
	require.NoError(t, d.QueryRow(`SELECT status FROM inbox_items WHERE trigger_type='calendar_invite'`).Scan(&status))
	assert.Equal(t, "resolved", status)
}

// TestRunPicksUpGmail: a Gmail message addressed to the current user's email
// should surface as an email_received inbox item, same as Slack/Jira/Calendar
// sources.
func TestRunPicksUpGmail(t *testing.T) {
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
	p.SetOwner(db.Owner{ID: "U1", SlackUserID: "U1", Email: "me@x.com"})

	_, _, err = p.Run(context.Background())
	require.NoError(t, err)

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
	require.Error(t, err, "a detector failure must be surfaced so the daemon records a failed run")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts,
		"detector failure must leave the inbox watermark untouched to avoid losing the skipped window")
}

// TestInbox09_SlackDetectorErrorFreezesWatermark guards INBOX-09 for the
// per-account Slack loop: a genuine detector failure must still freeze the
// shared watermark exactly like any other source's detector error. Contrast
// TestInbox09_UnresolvedSlackAccountSkippedDoesNotFreezeWatermark, which
// guards the other half — an unresolved account is a clean skip, not a
// failure, and must NOT freeze the watermark.
func TestInbox09_SlackDetectorErrorFreezesWatermark(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")

	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	// Break Slack detection specifically: FindPendingMentions/FindPendingDMs
	// both query messages, so dropping it makes detectSlackTriggers return a
	// genuine error without touching any other source's tables (mirrors
	// TestInbox09_WatermarkFrozenOnDetectorError's DROP TABLE jira_issues).
	_, err := d.Exec(`DROP TABLE messages`)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.Error(t, err, "a detector failure must be surfaced so the daemon records a failed run")

	tsAfter, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, tsAfter, "a genuine Slack detector error must freeze the watermark")
}

// TestInbox09_UnresolvedSlackAccountSkippedDoesNotFreezeWatermark guards the
// other half of the same contract (see TestInbox09_SlackDetectorErrorFreezesWatermark):
// an enabled account whose current_user_id was never resolved must be
// skipped cleanly, not treated as a detector error, because it has provably
// never synced a single message — connectSlackAccount (cmd/slack.go) writes
// current_user_id before it saves the token, and wireSlackSyncers refuses to
// build a syncer without a token, so there is no window of messages to lose
// by skipping it. A sibling account's detection must still succeed and the
// watermark must advance normally, not freeze.
func TestInbox09_UnresolvedSlackAccountSkippedDoesNotFreezeWatermark(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")

	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	ts := recentTS(30)
	insertChannel(t, d, "1:C1", "public")
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> review please')`, ts)
	require.NoError(t, err)

	// Account 2 is enabled but its current_user_id was never resolved — the
	// window between CreateSlackAccount and UpdateSlackAccountConnection
	// finishing OAuth, e.g. a crash mid-login. No token can exist for this
	// account yet either (see the doc comment above), so nothing was lost.
	_, err = d.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1, "account 1's mention must still be created despite account 2 having no identity")
	assert.Equal(t, "1:C1", items[0].ChannelID)

	tsAfter, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Greater(t, tsAfter, frozen,
		"an unresolved-identity account must be skipped cleanly and must not freeze the watermark")
}

// TestInbox09Gap_SlackAccountGenuineErrorSiblingIsolation documents a known,
// investigated gap — it is deliberately named outside the TestInbox09_
// guard-test convention and is NOT listed in docs/inventory/inbox-pulse.md's
// INBOX-09 Test guards, since a skipped test proves nothing and listing it
// there would be exactly the kind of overclaim this branch's review rounds
// have been correcting elsewhere.
//
// What it would guard: with two accounts, the first hitting a genuine
// (non-skip) detector error, the second must still be attempted — its item
// created, the joined error still returned, the watermark still frozen.
// TestInbox09_SlackDetectorErrorFreezesWatermark cannot stand in for this:
// it seeds a single account, so a regression that turned detectSlackAccounts'
// per-account "append the error and keep looping" into an early return would
// not be observable there (there is no second account to fail to reach).
// Confirmed empirically: temporarily changing that loop's
// `errs = append(...)` branch to `return created, fmt.Errorf(...)` left the
// entire internal/inbox suite green (160/160) before this test existed —
// the regression was, and without this test remains, unguarded.
//
// Investigated and rejected, in order:
//  1. Corrupting one account's messages/reactions rows to make its own
//     FindPendingMentions/FindPendingDMs query fail while a sibling
//     account's identical query (same SQL text, different bind parameters)
//     succeeds. Every column either detector actually scans is NOT NULL
//     (channel_id, ts, user_id, text, permalink, reactions.user_id — all
//     schema.sql), COALESCE-wrapped (thread_ts), or a NOT-NULL-derived
//     GENERATED ALWAYS ... STORED column fed by SQLite's lenient TEXT->REAL
//     CAST, which cannot produce NULL from a NOT NULL source (ts_unix).
//     FindPendingDMs' JOIN with channels and FindReactionRequests' JOIN with
//     reactions were checked too: neither query actually SELECTs a column
//     from its join partner that isn't already covered above.
//  2. SQLite enforces CHECK/NOT NULL constraints at write time, not read
//     time, so no reachable row state can defer a failure into a later
//     SELECT — only a table-wide DROP TABLE (breaks every account's query
//     uniformly, not just one) or a query-syntax break is achievable, and
//     both already have coverage via TestInbox09_SlackDetectorErrorFreezesWatermark
//     and TestInbox09_WatermarkFrozenOnDetectorError respectively.
//  3. No DB-layer test seam exists anywhere in this repo to fake a
//     per-call failure: db.DB embeds *sql.DB directly with no hook/
//     interceptor, no test in internal/db or internal/inbox uses a mock/
//     fake driver, and go.mod carries no SQL-mocking dependency (e.g.
//     DATA-DOG/go-sqlmock). Building one — a custom driver.Driver, or
//     restructuring detectSlackAccounts to accept an injectable querier —
//     is a production/test-infrastructure change, not a test, and was not
//     undertaken here.
//
// The property still holds by code shape today: there is no continue/return
// after `errs = append(...)` in detectSlackAccounts, so execution always
// falls through to the next account. That must be preserved by code review
// until a real test mechanism is found.
func TestInbox09Gap_SlackAccountGenuineErrorSiblingIsolation(t *testing.T) {
	t.Skip("no mechanism found to make one Slack account's detector query fail while a sibling's succeeds against the same shared tables — see the doc comment above for what was tried; reported as a documented limitation, not silently treated as covered")
}

// TestAutoResolveJira_CommentEditIsNotAnAnswer pins that auto-resolve keys on
// a comment's CREATION only: editing an own comment that predates the item
// does not resolve it (the edit counts only toward the detector's own-bump
// suppression).
func TestAutoResolveJira_CommentEditIsNotAnAnswer(t *testing.T) {
	d := newTestDB(t)
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	p.SetOwner(db.Owner{ID: "alice", SlackUserID: "alice", Email: "alice@x.com", JiraAccountID: "acc-alice"})
	seedJiraComment(t, d, "WT-20", "acc-alice", "old note", time.Now().Add(-2*time.Hour))
	mustCreateInboxItem(t, d, db.InboxItem{ChannelID: "WT-20", MessageTS: "x", SenderUserID: "WT-20",
		TriggerType: "jira_assigned", ItemClass: "actionable", Status: "pending", Priority: "medium"})
	_, err := d.Exec(`UPDATE jira_comments SET updated_at = ? WHERE issue_key = 'WT-20'`,
		db.FormatJiraTime(time.Now().Add(5*time.Second).UTC()))
	require.NoError(t, err)

	assert.Equal(t, 0, p.autoResolveJira(context.Background(), newOwnJiraComments(d, p.owner)))
}

// rescheduleForTest syncs evt-tc twice through the production upsert: first
// at start, then moved by a day (or to movedStart when non-zero) with the
// owner's RSVP set to rsvpAfterMove on that same pass. Returns the event's
// new start.
func rescheduleForTest(t *testing.T, d *db.DB, rsvpBefore, rsvpAfterMove string, movedStart time.Time) time.Time {
	t.Helper()
	att := func(rsvp string) string {
		return `[{"email":"alice@x.com","response_status":"` + rsvp + `"}]`
	}
	start := time.Now().Add(3 * time.Hour)
	syncCalendarEvent(t, d, "evt-tc", att(rsvpBefore), start, start.Add(time.Hour),
		time.Now().Add(-3*time.Hour), time.Now().Add(-2*time.Hour))
	moved := start.Add(24 * time.Hour)
	if !movedStart.IsZero() {
		moved = movedStart
	}
	syncCalendarEvent(t, d, "evt-tc", att(rsvpAfterMove), moved, moved.Add(time.Hour),
		time.Now().Add(-30*time.Minute), time.Now().Add(-10*time.Minute))
	return moved
}

func timeChangeStatus(t *testing.T, d *db.DB) (string, string) {
	t.Helper()
	got := queryInboxByTrigger(t, d, "calendar_time_change")
	require.Len(t, got, 1, "the reschedule is detected")
	return got[0].Status, got[0].ResolvedReason
}

// TestInbox02_CalendarTimeChangeKeptRSVPStaysPending: owner decision
// 2026-09-29 — an RSVP the owner gave BEFORE the reschedule does not answer
// it. The provider keeping "accepted" across the move leaves the item pending.
func TestInbox02_CalendarTimeChangeKeptRSVPStaysPending(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	rescheduleForTest(t, d, "accepted", "accepted", time.Time{})
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	status, _ := timeChangeStatus(t, d)
	assert.Equal(t, "pending", status)
}

// TestInbox02_CalendarTimeChangeResolvesOnRSVPAfterMove: the provider keeps
// the owner's "accepted" across the move (the item stays pending); the owner
// then changes their answer — a later sync sees the change after the
// reschedule and the item resolves.
func TestInbox02_CalendarTimeChangeResolvesOnRSVPAfterMove(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	moved := rescheduleForTest(t, d, "accepted", "accepted", time.Time{})
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	status, _ := timeChangeStatus(t, d)
	require.Equal(t, "pending", status, "an RSVP kept from before the move is not an answer")

	syncCalendarEvent(t, d, "evt-tc", `[{"email":"alice@x.com","response_status":"tentative"}]`,
		moved, moved.Add(time.Hour), time.Now(), time.Now())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	status, reason := timeChangeStatus(t, d)
	assert.Equal(t, "resolved", status)
	assert.Equal(t, "User responded after the reschedule", reason)
}

// TestCalendarReschedule_ProviderResetSurfacesAsInvite: when the provider
// resets the owner's RSVP to needsAction with the move, the invite case
// (checked first) surfaces it as a calendar_invite, which resolves as soon as
// the owner answers — no calendar_time_change item is minted.
func TestCalendarReschedule_ProviderResetSurfacesAsInvite(t *testing.T) {
	d := newTestDB(t)
	moved := rescheduleForTest(t, d, "accepted", "needsAction", time.Time{})
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Empty(t, queryInboxByTrigger(t, d, "calendar_time_change"))
	invites := queryInboxByTrigger(t, d, "calendar_invite")
	require.Len(t, invites, 1)
	require.Equal(t, "pending", invites[0].Status)

	syncCalendarEvent(t, d, "evt-tc", `[{"email":"alice@x.com","response_status":"accepted"}]`,
		moved, moved.Add(time.Hour), time.Now(), time.Now())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	var status string
	require.NoError(t, d.QueryRow(`SELECT status FROM inbox_items WHERE id = ?`, invites[0].ID).Scan(&status))
	assert.Equal(t, "resolved", status)
}

// TestInbox02_CalendarTimeChangeResolvesOnAnswerWithTheMove: an RSVP change
// to an answer first seen on the same sync pass as the move counts as an
// answer to the moved meeting — the sync cannot order the two, so it resolves.
func TestInbox02_CalendarTimeChangeResolvesOnAnswerWithTheMove(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	rescheduleForTest(t, d, "declined", "accepted", time.Time{})
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	status, _ := timeChangeStatus(t, d)
	assert.Equal(t, "resolved", status)
}

// TestInbox02_CalendarTimeChangeResolvesOnceEnded: unanswered, the item
// stays pending only until the event has ended.
func TestInbox02_CalendarTimeChangeResolvesOnceEnded(t *testing.T) {
	// BEHAVIOR INBOX-02 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	rescheduleForTest(t, d, "accepted", "accepted", time.Now().Add(-3*time.Hour))
	p := newPipelineForTest(t, d, "alice", "alice@x.com")
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	status, reason := timeChangeStatus(t, d)
	assert.Equal(t, "resolved", status)
	assert.Equal(t, "Event has ended", reason)
}

// TestInbox09_OwnJiraCommentReadErrorFreezesWatermark: the jira_assigned
// detector's own-comment read failing is a detector error — Run returns it
// and the watermark stays where it was.
func TestInbox09_OwnJiraCommentReadErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	p := newPipelineForTest(t, d, "U_ME", "me@x.com")
	p.SetOwner(db.Owner{ID: "U_ME", SlackUserID: "U_ME", Email: "me@x.com", JiraAccountID: "acc-me"})
	seedJiraIssue(t, d, "WT-30", "acc-me", time.Now().Add(-1*time.Hour))
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	// jira_comments still exists (so the owner's identity resolves), but the
	// own-comment read itself fails.
	_, err := d.Exec(`ALTER TABLE jira_comments RENAME COLUMN author_account_id TO author_gone`)
	require.NoError(t, err)

	_, _, err = p.Run(context.Background())
	require.Error(t, err)
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts)
	assert.Empty(t, queryInboxByTrigger(t, d, "jira_assigned"), "nothing is minted past a failed read")
}

// TestInbox09_ReactionDetectorErrorFreezesWatermark: a failed reaction-request
// query is a detector error like a failed mention query — Run returns it and
// the watermark stays put, so the window is re-scanned. The account's
// mention, found by a query that succeeded, is still surfaced.
func TestInbox09_ReactionDetectorErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	insertChannel(t, d, "1:C1", "public")
	insertMessage(t, d, "1:C1", recentTS(30), "1:U_OTHER", "Hey <@U_ME1> review please")
	// Only FindReactionRequests reads reactions.
	_, err := d.Exec(`DROP TABLE reactions`)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.Error(t, err, "a reaction-detector failure must be surfaced, not logged and dropped")
	assert.Contains(t, err.Error(), "finding reaction requests")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts, "a reaction-detector failure must freeze the watermark")
	assert.Len(t, queryInboxByTrigger(t, d, "mention"), 1, "the mention found by a healthy query is still surfaced")
}

// TestInbox09_SlackItemWriteErrorFreezesWatermark: a failed inbox_items
// insert for a Slack candidate (other than a UNIQUE conflict) is a detector
// error — the candidate was never surfaced, so the window must be re-scanned.
func TestInbox09_SlackItemWriteErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	insertChannel(t, d, "1:C1", "public")
	insertMessage(t, d, "1:C1", recentTS(30), "1:U_OTHER", "Hey <@U_ME1> review please")
	_, err := d.Exec(`CREATE TRIGGER fail_mention BEFORE INSERT ON inbox_items
		WHEN NEW.trigger_type = 'mention' BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END`)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "creating item")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts, "an unsurfaced candidate must freeze the watermark")
}

// TestInbox09_JiraCommentMentionReadErrorFreezesWatermark: a failed
// jira_comments mention read is a detector error, never "no mentions".
func TestInbox09_JiraCommentMentionReadErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	p := newPipelineForTest(t, d, "U_ME", "me@x.com")
	p.SetOwner(db.Owner{ID: "U_ME", SlackUserID: "U_ME", Email: "me@x.com", JiraAccountID: "acc-me"})
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	// The owner's own-comment read (author_account_id) still works; only the
	// mention scan (body_text) fails.
	_, err := d.Exec(`ALTER TABLE jira_comments RENAME COLUMN body_text TO body_gone`)
	require.NoError(t, err)

	_, _, err = p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "jira_comments")
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts)
}

// TestInbox09_JiraItemWriteErrorFreezesWatermark: a failed insert of a Jira
// item is returned, not dropped — for both Jira signals — and does not stop
// the other signal from surfacing its item.
func TestInbox09_JiraItemWriteErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	for trigger, other := range map[string]string{"jira_assigned": "jira_comment_mention", "jira_comment_mention": "jira_assigned"} {
		t.Run(trigger, func(t *testing.T) {
			d := newTestDB(t)
			p := newPipelineForTest(t, d, "U_ME", "me@x.com")
			p.SetOwner(db.Owner{ID: "U_ME", SlackUserID: "U_ME", Email: "me@x.com", JiraAccountID: "acc-me"})
			seedJiraIssue(t, d, "WT-40", "acc-me", time.Now().Add(-1*time.Hour))
			seedJiraComment(t, d, "WT-40", "acc-bob", "hey [~acc-me] please look", time.Now().Add(-30*time.Minute))
			const frozen = 1000.0
			require.NoError(t, d.SetInboxLastProcessedTS(frozen))
			_, err := d.Exec(`CREATE TRIGGER fail_jira BEFORE INSERT ON inbox_items
				WHEN NEW.trigger_type = '` + trigger + `' BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END`)
			require.NoError(t, err)

			_, _, err = p.Run(context.Background())
			require.Error(t, err)
			assert.Contains(t, err.Error(), trigger)
			ts, err := d.GetInboxLastProcessedTS()
			require.NoError(t, err)
			assert.Equal(t, frozen, ts)
			assert.Len(t, queryInboxByTrigger(t, d, other), 1, "the other Jira signal still surfaces")
		})
	}
}

// TestInbox09_JiraIdentityReadErrorFreezesWatermark: a failed read of the
// owner's Atlassian ids is a detector error — never read as "the owner has
// no Jira identity", which would skip comment-mention detection silently.
func TestInbox09_JiraIdentityReadErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	p := newPipelineForTest(t, d, "U_ME", "me@x.com")
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	_, err := d.Exec(`DROP TABLE jira_user_map`)
	require.NoError(t, err)

	_, _, err = p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "jira_user_map")
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts)
}

// TestInbox09_WatermarkBoundedBySyncStart guards INBOX-09's sync bound
// (owner-approved 2026-10-01): a clean pass advances the watermark to this
// cycle's sync start − 30 min, not now − 30 min. A mention posted after the
// sync started but before the inbox ran (the cycle's AI phases take tens of
// minutes) reaches the DB only next cycle — it must still be ahead of the
// watermark and get detected.
func TestInbox09_WatermarkBoundedBySyncStart(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")
	require.NoError(t, d.SetInboxLastProcessedTS(1000))

	syncStart := time.Now().Add(-2 * time.Hour)
	p := New(d, testConfig(), nil, log.Default())
	p.SetSyncResult(syncStart, nil)
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, float64(syncStart.Add(-30*time.Minute).Unix()), ts,
		"the watermark must stop at the sync's start − 30 min, not now − 30 min")

	// Posted 5 minutes after that sync started, synced by the next cycle.
	insertMessage(t, d, "1:C1", recentTS(115), "1:U_OTHER", "Hey <@U_ME1> review please")
	p.SetSyncResult(time.Now(), nil)
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	assert.Len(t, queryInboxByTrigger(t, d, "mention"), 1,
		"a mention posted while the previous cycle ran must not fall behind the watermark")
}

// TestInbox09_SlackSyncErrorFreezesWatermark guards INBOX-09: a Slack sync
// error handed to Run freezes the watermark and is returned, while the data
// that did sync is still detected. The result is consumed: the next run
// without a sync error advances again.
func TestInbox09_SlackSyncErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")
	insertMessage(t, d, "1:C1", recentTS(30), "1:U_OTHER", "Hey <@U_ME1> review please")
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	p := New(d, testConfig(), nil, log.Default())
	p.SetSyncResult(time.Now(), errors.New("ratelimited"))
	_, _, err := p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "slack sync")
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts, "a sync error must freeze the watermark")
	assert.Len(t, queryInboxByTrigger(t, d, "mention"), 1, "what did sync is still surfaced")

	_, _, err = p.Run(context.Background())
	require.NoError(t, err, "the sync error belongs to one cycle only")
	ts, err = d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Greater(t, ts, frozen)
}

// TestInbox09_HeldRunDetectsWithoutMovingWatermark: a manual run
// (HoldWatermark) still surfaces what it finds but leaves the watermark to the
// daemon's next clean sync, and reports no error for it.
func TestInbox09_HeldRunDetectsWithoutMovingWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")
	insertMessage(t, d, "1:C1", recentTS(30), "1:U_OTHER", "Hey <@U_ME1> review please")
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))

	p := New(d, testConfig(), nil, log.Default())
	p.HoldWatermark()
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Len(t, queryInboxByTrigger(t, d, "mention"), 1)
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts)
}

// TestInbox09_OldSyncStartNeverRewindsWatermark: a sync result older than the
// watermark (a long cycle after a manual run moved it) never moves it back.
func TestInbox09_OldSyncStartNeverRewindsWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	current := float64(time.Now().Add(-10 * time.Minute).Unix())
	require.NoError(t, d.SetInboxLastProcessedTS(current))

	p := New(d, testConfig(), nil, log.Default())
	p.SetSyncResult(time.Now().Add(-2*time.Hour), nil)
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, current, ts)
}

// TestInbox09_SkippedRunConsumesSyncResult: a run skipped because the inbox
// is disabled still consumes the handed-over sync result, so a stale sync
// error never freezes a later cycle.
func TestInbox09_SkippedRunConsumesSyncResult(t *testing.T) {
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	require.NoError(t, d.SetInboxLastProcessedTS(1000))
	cfg := testConfig()
	p := New(d, cfg, nil, log.Default())

	cfg.Inbox.Enabled = false
	p.SetSyncResult(time.Now(), errors.New("ratelimited"))
	_, _, err := p.Run(context.Background())
	require.NoError(t, err)

	cfg.Inbox.Enabled = true
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Greater(t, ts, 1000.0)
}
