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
	// create item → ComposedAt empty; UPDATE via MarkSignalsComposed comes in Task 3,
	// here only assert the column scans (create + Get → ComposedAt == "").
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	id := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})

	it, err := d.GetInboxItem(id)
	require.NoError(t, err)
	require.Equal(t, "", it.ComposedAt)
}
