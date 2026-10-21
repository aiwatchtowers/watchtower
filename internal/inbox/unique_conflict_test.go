package inbox

import (
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// isUniqueConflict matches the engine's error text: a second inbox item for
// the same message must read as a UNIQUE conflict (a skip), and an unrelated
// failure must not.
func TestIsUniqueConflict_EngineError(t *testing.T) {
	d := testDB(t)
	it := db.InboxItem{ChannelID: "1:C1", MessageTS: "1700000000.000100", SenderUserID: "1:U1", TriggerType: "mention"}
	mustCreateInboxItem(t, d, it)
	_, err := d.CreateInboxItem(it)
	require.Error(t, err)
	require.True(t, isUniqueConflict(err), "duplicate insert: %v", err)

	_, err = d.Exec(`INSERT INTO inbox_items (channel_id) VALUES (NULL)`)
	require.Error(t, err)
	require.False(t, isUniqueConflict(err), "NOT NULL failure read as a UNIQUE conflict: %v", err)
}
