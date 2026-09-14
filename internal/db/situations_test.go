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

// insertSituation seeds a row into the frozen situations table with raw SQL.
// The table has no production writer any more (the inbox demolition removed the
// composer and the dashboard lifecycle), so the surviving readers are fixtured
// directly rather than through a writer kept alive for tests. status "" takes
// the column default ('open').
func insertSituation(t *testing.T, d *DB, title, status string) int {
	t.Helper()
	res, err := d.Exec(`INSERT INTO situations (title, status) VALUES (?, COALESCE(NULLIF(?, ''), 'open'))`, title, status)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return int(id)
}

// attachSituationSignal links an inbox item to a situation with raw SQL (see
// insertSituation on why the writer is gone).
func attachSituationSignal(t *testing.T, d *DB, situationID, inboxItemID int) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (?, ?)`,
		situationID, inboxItemID)
	require.NoError(t, err)
}

func TestSituationRoundTripAndSignals(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "1.1", "U2", "sig one")
	insertMessage(t, d, "C1", "2.1", "U2", "sig two")
	sig1 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "stream"})
	sig2 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "mention"})

	id := insertSituation(t, d, "release X blocked", "")

	attachSituationSignal(t, d, id, int(sig1))
	attachSituationSignal(t, d, id, int(sig2))
	members, err := d.ListSituationSignals(id)
	require.NoError(t, err)
	require.Len(t, members, 2)
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
