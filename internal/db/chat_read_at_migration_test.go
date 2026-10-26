package db

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00161_ExistingRowsReadNewRowsNull: a conversation that existed
// before the migration reads as already read (read_at = updated_at); one
// inserted after it starts with NULL.
func TestMigration00161_ExistingRowsReadNewRowsNull(t *testing.T) {
	path := filepath.Join(t.TempDir(), "w.db")
	d, err := Open(path)
	require.NoError(t, err)
	require.NoError(t, gooseDownTo(d.DB, "migrations", 160))
	_, err = d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (1, 'old', 10, 25.5)`)
	require.NoError(t, err)
	require.NoError(t, d.Close())

	d, err = Open(path)
	require.NoError(t, err)
	defer d.Close()

	var readAt float64
	require.NoError(t, d.QueryRow(`SELECT read_at FROM chat_conversations WHERE id = 1`).Scan(&readAt))
	assert.Equal(t, 25.5, readAt)

	_, err = d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (2, 'new', 30, 30)`)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = 2 AND read_at IS NULL`).Scan(&n))
	assert.Equal(t, 1, n)
}
