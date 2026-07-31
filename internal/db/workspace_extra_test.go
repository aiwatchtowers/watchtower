package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTouchSyncedAt(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.UpsertWorkspace(Workspace{ID: "T1", Name: "test", Domain: "test.slack.com"}))

	err := db.TouchSyncedAt()
	require.NoError(t, err)

	ws, err := db.GetWorkspace()
	require.NoError(t, err)
	assert.True(t, ws.SyncedAt.Valid)
}
