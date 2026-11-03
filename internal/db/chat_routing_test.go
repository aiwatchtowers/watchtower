package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestChatRoutingMigrationPinsOldAndDefaultsNew(t *testing.T) {
	d := OpenTestDB(t)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 171))
	_, err := d.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at,provider,model) VALUES(1,1,1,'claude','opus'),(2,1,1,NULL,NULL)`)
	require.NoError(t, err)
	require.NoError(t, gooseUp(d.DB, "migrations"))
	for _, id := range []int64{1, 2} {
		c, err := d.GetChatConversation(id)
		require.NoError(t, err)
		require.Equal(t, "pinned", c.RoutingMode)
	}
	_, err = d.Exec(`INSERT INTO chat_conversations(id,created_at,updated_at) VALUES(3,1,1)`)
	require.NoError(t, err)
	c, err := d.GetChatConversation(3)
	require.NoError(t, err)
	require.Equal(t, "preferred_reserve", c.RoutingMode)
	require.NoError(t, d.SetChatActual(3, "codex", "reserve-model", "quota_exhausted"))
	c, err = d.GetChatConversation(3)
	require.NoError(t, err)
	require.Equal(t, "codex", c.ActualProvider)
	require.Empty(t, c.Provider)
	require.NoError(t, d.SetChatRouting(3, "pinned", "claude", "opus"))
	c, err = d.GetChatConversation(3)
	require.NoError(t, err)
	require.Empty(t, c.ActualProvider)
	require.Equal(t, "opus", c.Model)
	require.Error(t, d.SetChatRouting(3, "invalid", "claude", ""))
	require.NoError(t, gooseDownTo(d.DB, "migrations", 171))
	require.NoError(t, gooseUp(d.DB, "migrations"))
	require.NoError(t, gooseUp(d.DB, "migrations"))
	c, err = d.GetChatConversation(1)
	require.NoError(t, err)
	require.Equal(t, "opus", c.Model)
}
