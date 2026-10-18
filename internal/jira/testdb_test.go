package jira

import (
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/require"
)

func openTestDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	db.SeedTestJiraAccount(t, database)
	return database
}
