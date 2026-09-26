package features

import (
	"errors"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// TestMain installs the migrated-DB clone template (the internal/daemon gate
// tests' precedent, Task 3) so every testDB(t) call below is a cheap clone
// instead of a full goose migration run.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		panic(err)
	}
	os.Exit(m.Run())
}

// testDB opens an isolated in-memory database with a workspace row seeded —
// every FastForward hook writes into workspace-scoped columns (directly or,
// for the per-account setters, via a row FK'd to nothing on workspace but
// still gated behind the same singleton existing in practice), and several
// of the workspace setters this test exercises (SetIdeasFloors) error on a
// missing row rather than silently no-op.
func testDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test-workspace", Domain: "test-workspace"}))
	return database
}

func TestFastForward_Inbox(t *testing.T) {
	database := testDB(t)
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

	require.NoError(t, FastForward("secretary-inbox", database, now, Deps{}))

	inboxTS, err := database.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, float64(now.Unix()), inboxTS)
}

func TestFastForward_Ideas(t *testing.T) {
	database := testDB(t)
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

	// Three digest_topics rows (under one digest) -> digest floor top = 3.
	digestID, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel", PeriodFrom: 1, PeriodTo: 2, Summary: "s",
	})
	require.NoError(t, err)
	require.NoError(t, database.InsertDigestTopics(digestID, []db.DigestTopic{
		{Title: "t1"}, {Title: "t2"}, {Title: "t3"},
	}))

	// Two stream_digests rows -> stream floor top = 2.
	_, err = database.InsertStreamDigest(db.StreamDigest{Source: "gmail", AccountID: 1, PeriodFrom: "a", PeriodTo: "b"})
	require.NoError(t, err)
	_, err = database.InsertStreamDigest(db.StreamDigest{Source: "jira", AccountID: 1, PeriodFrom: "a", PeriodTo: "b"})
	require.NoError(t, err)

	// One meeting_transcripts row -> transcript floor top = 1.
	_, err = database.InsertMeetingTranscript(db.MeetingTranscript{Title: "m1", TranscriptText: "hello"})
	require.NoError(t, err)

	// Per-account stage-1 floors seeded to known values: they belong to
	// Stream Digests (streams.enabled), which toggles independently of
	// Ideas, so an Ideas enable must leave them exactly where they are.
	gmailAcct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, database.SetGmailAccountWatermark(gmailAcct, 555))
	require.NoError(t, database.SetIdeasEmailFloor(gmailAcct, 111))

	jiraAcct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud-1", SiteURL: "https://x.atlassian.net"})
	require.NoError(t, err)
	seededJiraFloor := db.FormatJiraTime(time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC))
	require.NoError(t, database.SetIdeasJiraFloor(jiraAcct, seededJiraFloor))

	require.NoError(t, FastForward("ideas", database, now, Deps{}))

	digestFloor, streamFloor, transcriptFloor, err := database.GetIdeasFloors()
	require.NoError(t, err)
	assert.Equal(t, int64(3), digestFloor, "digest floor should equal MAX(digest_topics.id)")
	assert.Equal(t, int64(2), streamFloor, "stream floor should equal MAX(stream_digests.id)")
	assert.Equal(t, int64(1), transcriptFloor, "transcript floor should equal MAX(meeting_transcripts.id)")

	emailFloor, err := database.IdeasEmailFloor(gmailAcct)
	require.NoError(t, err)
	assert.Equal(t, float64(111), emailFloor,
		"enabling Ideas must not advance Stream Digests' per-account email floor — that would skip a generation window the owner never asked to skip")

	jiraFloor, err := database.IdeasJiraFloor(jiraAcct)
	require.NoError(t, err)
	assert.Equal(t, seededJiraFloor, jiraFloor,
		"enabling Ideas must not advance Stream Digests' per-account jira floor")
}

// TestFastForward_StreamDigests pins that "stream-digests" advances only the
// per-account Gmail/Jira stage-1 floors — never the workspace-level
// consolidator floors "ideas" also owns — since Stream Digests
// (streams.enabled) can be re-enabled independently of Ideas
// (ideas.enabled), and neither should trample the other's watermark.
func TestFastForward_StreamDigests(t *testing.T) {
	database := testDB(t)
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

	// A connected, Gmail-enabled account with a real sync watermark: its
	// ideas_email_floor fast-forwards to that watermark (self-init mirror),
	// not to "now".
	gmailAcct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, database.SetGmailAccountWatermark(gmailAcct, 777))

	// A Gmail-enabled account with NO synced mail yet (watermark still 0):
	// the degenerate clean-exit branch — must be left untouched, exactly
	// like the stage-1 self-init's own "retry initialization next run".
	freshGmailAcct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "fresh@x.com", GmailEnabled: true})
	require.NoError(t, err)

	// A connected Google account with Gmail NOT enabled: skipped entirely,
	// never touched.
	calendarOnlyAcct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "cal@x.com", GmailEnabled: false, CalendarEnabled: true})
	require.NoError(t, err)

	jiraAcct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud-1", SiteURL: "https://x.atlassian.net"})
	require.NoError(t, err)

	require.NoError(t, FastForward("stream-digests", database, now, Deps{}))

	emailFloor, err := database.IdeasEmailFloor(gmailAcct)
	require.NoError(t, err)
	assert.Equal(t, float64(777), emailFloor)

	freshEmailFloor, err := database.IdeasEmailFloor(freshGmailAcct)
	require.NoError(t, err)
	assert.Zero(t, freshEmailFloor, "an account with no synced mail yet must be left untouched")

	calOnlyFloor, err := database.IdeasEmailFloor(calendarOnlyAcct)
	require.NoError(t, err)
	assert.Zero(t, calOnlyFloor, "a Gmail-disabled account must be left untouched")

	jiraFloor, err := database.IdeasJiraFloor(jiraAcct)
	require.NoError(t, err)
	assert.Equal(t, db.FormatJiraTime(now.UTC()), jiraFloor)

	digestFloor, streamFloor, transcriptFloor, err := database.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, digestFloor, "stream-digests must not touch the workspace ideas floors")
	assert.Zero(t, streamFloor, "stream-digests must not touch the workspace ideas floors")
	assert.Zero(t, transcriptFloor, "stream-digests must not touch the workspace ideas floors")
}

// TestFastForward_SlackDigests pins that "slack-digests" stamps the workspace
// fast-forward floor to now — the persisted watermark Slack digests otherwise
// lack — and touches nothing else.
func TestFastForward_SlackDigests(t *testing.T) {
	database := testDB(t)
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

	require.NoError(t, FastForward("slack-digests", database, now, Deps{}))

	ffTS, err := database.GetDigestFastForwardTS()
	require.NoError(t, err)
	assert.Equal(t, float64(now.Unix()), ffTS)

	// The four watermarks owned by the other hooks stay untouched.
	inboxTS, err := database.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Zero(t, inboxTS)

	digestFloor, streamFloor, transcriptFloor, err := database.GetIdeasFloors()
	require.NoError(t, err)
	assert.Zero(t, digestFloor)
	assert.Zero(t, streamFloor)
	assert.Zero(t, transcriptFloor)
}

func TestFastForward_Memory(t *testing.T) {
	database := testDB(t)
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)

	gmailAcct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@x.com", GmailEnabled: true})
	require.NoError(t, err)
	calendarOnlyAcct, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "cal@x.com", GmailEnabled: false, CalendarEnabled: true})
	require.NoError(t, err)
	jiraAcct, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud-1", SiteURL: "https://x.atlassian.net"})
	require.NoError(t, err)

	require.NoError(t, FastForward("memory", database, now, Deps{}))

	ts, err := database.MemoryWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(now.Unix()), ts)

	gmailWM, err := database.MemoryGmailWatermark(gmailAcct)
	require.NoError(t, err)
	assert.Equal(t, float64(now.Unix()), gmailWM)

	calOnlyWM, err := database.MemoryGmailWatermark(calendarOnlyAcct)
	require.NoError(t, err)
	assert.Zero(t, calOnlyWM, "a Gmail-disabled account's memory gmail watermark must be left untouched")

	jiraWM, err := database.MemoryJiraWatermark(jiraAcct)
	require.NoError(t, err)
	assert.Equal(t, float64(now.Unix()), jiraWM)

	calWM, err := database.MemoryCalendarWatermark()
	require.NoError(t, err)
	assert.Equal(t, float64(now.Unix()), calWM)
}

// TestFastForward_ReactionCommands pins the sixth hook: enabling reaction
// commands runs the injected ledger seed, and an enable whose seed fails (Slack
// unreachable, an account with no usable token) fails the hook — which is what
// keeps `features enable` from writing the config key (FEAT-03's fail-closed
// ordering, pinned end to end by cmd/features_test.go's
// TestFeaturesEnable_FailedFastForwardLeavesKeyUnwritten).
func TestFastForward_ReactionCommands(t *testing.T) {
	database := testDB(t)
	now := time.Now()

	called := 0
	require.NoError(t, FastForward("reaction-commands", database, now, Deps{
		SeedReactions: func(d *db.DB) error {
			called++
			assert.Same(t, database, d, "the hook seeds the database it was handed")
			return nil
		},
	}))
	assert.Equal(t, 1, called, "the seed runs on enable")

	boom := errors.New("slack unreachable")
	err := FastForward("reaction-commands", database, now, Deps{
		SeedReactions: func(*db.DB) error { return boom },
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, boom, "a seed failure fails the enable")

	// A caller that forgot to wire the seeder must NOT silently succeed: that
	// would enable the feature over an empty ledger, the exact state whose
	// first poll replays the owner's whole reaction history.
	require.Error(t, FastForward("reaction-commands", database, now, Deps{}))
}

// TestFastForward_NoHookIsNil pins FEAT-03's "every other id" half: every
// registry feature without a fast-forward hook returns nil and writes
// nothing to any of the watermarks/floors the four real hooks own.
func TestFastForward_NoHookIsNil(t *testing.T) {
	database := testDB(t)
	now := time.Now()

	assertNoWatermarksWritten := func(t *testing.T) {
		t.Helper()
		inboxTS, err := database.GetInboxLastProcessedTS()
		require.NoError(t, err)
		assert.Zero(t, inboxTS)

		digestFloor, streamFloor, transcriptFloor, err := database.GetIdeasFloors()
		require.NoError(t, err)
		assert.Zero(t, digestFloor)
		assert.Zero(t, streamFloor)
		assert.Zero(t, transcriptFloor)

		memTS, err := database.MemoryWatermark()
		require.NoError(t, err)
		assert.Zero(t, memTS)

		calTS, err := database.MemoryCalendarWatermark()
		require.NoError(t, err)
		assert.Zero(t, calTS)

		ffTS, err := database.GetDigestFastForwardTS()
		require.NoError(t, err)
		assert.Zero(t, ffTS)
	}

	require.NoError(t, FastForward("briefing", database, now, Deps{}))
	assertNoWatermarksWritten(t)

	// Every other registry id without one of the four real hooks: same
	// contract, not just the one the brief names.
	hookIDs := map[string]bool{
		"secretary-inbox": true,
		"ideas":           true,
		"stream-digests":  true,
		"slack-digests":   true,
		"memory":          true,
		// Reaction commands seed the ledger through the deps seam; its own
		// test below covers both the wired and the unwired call.
		"reaction-commands": true,
	}
	for _, f := range All() {
		if hookIDs[f.ID] {
			continue
		}
		require.NoError(t, FastForward(f.ID, database, now, Deps{}), "id %q", f.ID)
	}
	assertNoWatermarksWritten(t)

	// An id not even in the registry must also be a safe no-op.
	require.NoError(t, FastForward("not-a-real-feature", database, now, Deps{}))
	assertNoWatermarksWritten(t)
}
