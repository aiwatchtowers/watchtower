package memory

import (
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

// seedJiraIssue inserts a minimal jira_issues row for a project key.
func seedJiraIssue(t *testing.T, d *db.DB, key, projectKey string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO jira_issues (key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES (?, ?, 'issue', 'Open', 'To Do', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')`,
		key, projectKey)
	require.NoError(t, err)
}

func TestSeedPersonNodeShape(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice Adams", "alice@example.com", 0)
	seedChannel(t, d, "C1GEN", "general", "General chat", "")
	seedMessages(t, d, "C1GEN", "U1ALICE", 5)
	cardID := seedPeopleCard(t, d, "U1ALICE", "Team lead for billing.")

	created, err := SeedEntities(v, d, seedTestConfig)
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

	_, err := SeedEntities(v, d, seedTestConfig)
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

	_, err := SeedEntities(v, d, seedTestConfig)
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

	_, err := SeedEntities(v, d, seedTestConfig)
	require.NoError(t, err)

	n, err := Resolve(v, d, "C3OPS")
	require.NoError(t, err)
	assert.Contains(t, n.Body, "## What\nOperational firefighting\n")
}

func TestSeedJiraProjectNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedJiraIssue(t, d, "PROJX-1", "PROJX")
	seedJiraIssue(t, d, "PROJX-2", "PROJX")

	created, err := SeedEntities(v, d, seedTestConfig)
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

	_, err := SeedEntities(v, d, seedTestConfig)
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

	created, err := SeedEntities(v, d, seedTestConfig)
	require.NoError(t, err)
	assert.Equal(t, 3, created)

	repo := openTestRepo(t, v.path)
	commitsAfterFirst := commitCount(t, repo)
	nodesAfterFirst, err := d.ListMemoryNodes()
	require.NoError(t, err)

	created, err = SeedEntities(v, d, seedTestConfig)
	require.NoError(t, err)
	assert.Zero(t, created, "second run creates nothing")

	assert.Equal(t, commitsAfterFirst, commitCount(t, repo), "no new commit when nothing to create")
	nodesAfterSecond, err := d.ListMemoryNodes()
	require.NoError(t, err)
	assert.Equal(t, len(nodesAfterFirst), len(nodesAfterSecond), "node count unchanged")
}

// seedGmailMessage inserts a gmail_messages row. internalDateISO is the RFC3339
// message time (what the Gmail sync stores — NOT the raw ms-epoch API value).
func seedGmailMessage(t *testing.T, d *db.DB, id, threadID, fromEmail, fromName, subject, body, internalDateISO string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO gmail_messages
		(id, thread_id, from_email, from_name, subject, body_text, internal_date)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, threadID, fromEmail, fromName, subject, body, internalDateISO)
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

	created, err := SeedEntities(v, d, seedGmailTestConfig)
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

	created, err := SeedEntities(v, d, seedGmailTestConfig)
	require.NoError(t, err)
	assert.Zero(t, created, "a below-threshold sender is not seeded")

	seedGmailSenderN(t, d, "sparse@example.com", "Sparse", 3) // now 5 total, over the floor
	created, err = SeedEntities(v, d, seedGmailTestConfig)
	require.NoError(t, err)
	assert.Equal(t, 1, created, "the same sender is seeded once it clears the floor")
}

// TestSeedGmailSenderMachineSenderDropped: an automated sender (no-reply@) is
// never seeded no matter how high its volume (the machine-sender pattern gate).
func TestSeedGmailSenderMachineSenderDropped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "no-reply@vendor.io", "Vendor Bot", 25) // high volume
	seedGmailSenderN(t, d, "notifications@github.com", "GitHub", 10)

	created, err := SeedEntities(v, d, seedGmailTestConfig)
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

	_, err := SeedEntities(v, d, seedGmailTestConfig)
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

	created, err := SeedEntities(v, d, seedGmailTestConfig)
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

	created, err := SeedEntities(v, d, seedTestConfig) // Gmail: false
	require.NoError(t, err)
	assert.Zero(t, created, "no senders seeded when the gmail source is off")
}

// TestSeedGmailSenderIdempotent: re-running SeedEntities creates no second
// entity for the same sender.
func TestSeedGmailSenderIdempotent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedGmailSenderN(t, d, "sender@example.com", "Sender", 3)

	created, err := SeedEntities(v, d, seedGmailTestConfig)
	require.NoError(t, err)
	require.Equal(t, 1, created)

	created, err = SeedEntities(v, d, seedGmailTestConfig)
	require.NoError(t, err)
	assert.Zero(t, created, "second run creates nothing")
}

// TestSeedGmailSenderOutsideWindowSkipped: a sender whose only message predates
// the seed window is not seeded.
func TestSeedGmailSenderOutsideWindowSkipped(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	old := time.Now().AddDate(0, 0, -60).UTC().Format(time.RFC3339)
	seedGmailMessage(t, d, "m1", "t1", "stale@example.com", "Stale", "Hi", "body", old)

	created, err := SeedEntities(v, d, seedTestConfig)
	require.NoError(t, err)
	assert.Zero(t, created, "out-of-window sender not seeded")
}

func TestSeedCommitMessage(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	seedUser(t, d, "U1ALICE", "Alice", "", 0)
	seedChannel(t, d, "C1GEN", "general", "", "")
	seedMessages(t, d, "C1GEN", "U1ALICE", 3)

	created, err := SeedEntities(v, d, seedTestConfig)
	require.NoError(t, err)
	require.Equal(t, 2, created)

	head := headCommit(t, openTestRepo(t, v.path))
	assert.Contains(t, head.Message, "memory(seed): 2 entities")
}
