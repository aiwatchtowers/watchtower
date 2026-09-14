package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// seedWorkspace is a shared fixture helper for tests needing a workspace row.
func seedWorkspace(t *testing.T, d *DB) {
	t.Helper()
	require.NoError(t, d.UpsertWorkspace(Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}))
}

func TestSituationRoundTripAndSignals(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	insertMessage(t, d, "C1", "2.1", "U2", "sig two")
	sig1 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})
	sig2 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "mention"})

	id, err := d.CreateSituation(DashboardSituation{Title: "release X blocked", Kind: "external", Priority: "high", Rank: 0.9, AIReason: "prod impact"})
	require.NoError(t, err)
	s, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "open", s.Status, "status must default open")
	require.Equal(t, "none", s.CardStatus)

	require.NoError(t, d.AddSituationSignals(int(id), []int{int(sig1), int(sig2)}))
	require.NoError(t, d.AddSituationSignals(int(id), []int{int(sig1)})) // idempotent
	members, err := d.ListSituationSignals(int(id))
	require.NoError(t, err)
	require.Len(t, members, 2)

	open, err := d.ListOpenSituations()
	require.NoError(t, err)
	require.Len(t, open, 1)
}

func TestComposeWatermarkRoundTrip(t *testing.T) {
	d := openTestDB(t)
	seedWorkspace(t, d) // use this file's actual workspace fixture helper
	ts, err := d.GetComposeLastRunTS()
	require.NoError(t, err)
	require.Equal(t, 0.0, ts)
	require.NoError(t, d.SetComposeLastRunTS(123.5))
	ts, _ = d.GetComposeLastRunTS()
	require.Equal(t, 123.5, ts)
}

func TestInboxItemComposedAtRoundTrip(t *testing.T) {
	// A freshly created item has an empty ComposedAt; assert the column scans.
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	id := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})

	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	require.Equal(t, "", it.ComposedAt)
}

func TestMarkSituationConverted(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSituation(DashboardSituation{Title: "convert me"})
	require.NoError(t, err)
	targetID, err := d.CreateTarget(Target{Text: "converted target", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	require.NoError(t, d.MarkSituationConverted(int(id), int(targetID), 0))

	s, err := d.GetSituation(int(id))
	require.NoError(t, err)
	require.Equal(t, "converted", s.Status)
	require.NotNil(t, s.ConvertedTargetID)
	require.Equal(t, int(targetID), *s.ConvertedTargetID)
	require.Nil(t, s.ConvertedTrackID)
}

func containsSituationID(situations []DashboardSituation, id int) bool {
	for _, s := range situations {
		if s.ID == id {
			return true
		}
	}
	return false
}

func TestListSituationsFiltersByStatusAndSince(t *testing.T) {
	d := openTestDB(t)

	mk := func(title, status, lastSignal string, rank float64) int {
		t.Helper()
		res, err := d.Exec(`INSERT INTO situations (title, status, rank, last_signal_at)
			VALUES (?, ?, ?, ?)`, title, status, rank, lastSignal)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return int(id)
	}

	openNew := mk("fresh open", "open", "2026-08-08T10:00:00Z", 5)
	mk("old open", "open", "2026-08-01T10:00:00Z", 9)
	mk("done one", "done", "2026-08-08T11:00:00Z", 7)
	noSignalID := mk("no signal yet", "open", "", 1)

	// Status filter.
	got, err := d.ListSituations(SituationFilter{Status: "open"})
	require.NoError(t, err)
	require.Len(t, got, 3)
	require.Equal(t, "old open", got[0].Title, "highest rank first")
	require.True(t, containsSituationID(got, noSignalID), "a situation with no signal yet must be present when no SinceISO bound is given")

	// Since filter applies to last_signal_at, and a situation that never
	// received a signal (last_signal_at = '') is deliberately excluded once a
	// bound is given — it sorts below any real timestamp.
	got, err = d.ListSituations(SituationFilter{Status: "open", SinceISO: "2026-08-05T00:00:00Z"})
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, openNew, got[0].ID)
	require.False(t, containsSituationID(got, noSignalID), "a situation with no signal yet must be excluded once a SinceISO bound is given")

	// No filter returns every status.
	got, err = d.ListSituations(SituationFilter{})
	require.NoError(t, err)
	require.Len(t, got, 4)

	// Limit is honored.
	got, err = d.ListSituations(SituationFilter{Limit: 1})
	require.NoError(t, err)
	require.Len(t, got, 1)
}
