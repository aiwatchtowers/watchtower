package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// setPresence upserts the presence row the way the Desktop does.
func setPresence(t *testing.T, d *DB, session any, seenAt string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, ?, ?)
		ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id, seen_at = excluded.seen_at`, session, seenAt)
	require.NoError(t, err)
}

func TestOwnerPresentInStaleWriteIsAbsent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newTestSession(t, d, pid)
	other := newTestSession(t, d, pid)
	now := time.Now().UTC().Truncate(time.Millisecond)

	present, err := d.OwnerPresentIn(sid, now)
	require.NoError(t, err)
	assert.False(t, present, "no row")

	for _, tc := range []struct {
		name    string
		session any
		seenAt  string
		want    bool
	}{
		{"seen now", sid, AgentStateStamp(now), true},
		{"seen 89 s ago", sid, AgentStateStamp(now.Add(-89 * time.Second)), true},
		{"seen 90 s ago", sid, AgentStateStamp(now.Add(-90 * time.Second)), true},
		{"seen 91 s ago", sid, AgentStateStamp(now.Add(-91 * time.Second)), false},
		{"4 s in the future", sid, AgentStateStamp(now.Add(4 * time.Second)), true},
		{"6 s in the future", sid, AgentStateStamp(now.Add(6 * time.Second)), false},
		{"in another session", other, AgentStateStamp(now), false},
		{"in no session", nil, AgentStateStamp(now), false},
		{"an unreadable stamp", sid, "yesterday", false},
		{"an empty stamp", sid, "", false},
	} {
		setPresence(t, d, tc.session, tc.seenAt)
		present, err := d.OwnerPresentIn(sid, now)
		require.NoError(t, err, tc.name)
		assert.Equal(t, tc.want, present, tc.name)
	}
}
