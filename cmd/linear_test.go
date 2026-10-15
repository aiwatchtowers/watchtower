package cmd

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestResolveLinearAccount(t *testing.T) {
	database := db.OpenTestDB(t)
	_, err := resolveLinearAccount(database, 0)
	assert.ErrorContains(t, err, "no Linear workspace connected")
	a, err := database.CreateLinearAccount("A")
	require.NoError(t, err)
	got, err := resolveLinearAccount(database, 0)
	require.NoError(t, err)
	assert.Equal(t, a, got.ID)
	b, err := database.CreateLinearAccount("B")
	require.NoError(t, err)
	_, err = resolveLinearAccount(database, 0)
	assert.ErrorContains(t, err, "--account")
	require.NoError(t, database.SetLinearAccountRemoved(b))
	_, err = resolveLinearAccount(database, b)
	assert.ErrorContains(t, err, "was removed")
}

func TestPrintLinearAccountsJSON(t *testing.T) {
	database := db.OpenTestDB(t)
	id, err := database.CreateLinearAccount("Work")
	require.NoError(t, err)
	require.NoError(t, database.UpdateLinearAccountConnection(id, "org-1", "acme", "Acme"))
	var buf bytes.Buffer
	require.NoError(t, printLinearAccounts(&buf, database, true))
	var rows []map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &rows))
	require.Len(t, rows, 1)
	assert.Equal(t, "https://linear.app/acme", rows[0]["url"])
	for _, k := range []string{"id", "label", "org_name", "url", "status", "enabled", "error"} {
		assert.Contains(t, rows[0], k)
	}
}

func TestLinearCommandsRegistered(t *testing.T) {
	for _, name := range []string{"add", "login", "accounts", "enable", "disable", "remove", "teams", "sync", "status"} {
		c, _, err := linearCmd.Find([]string{name})
		require.NoError(t, err, name)
		assert.Equal(t, name, c.Name())
	}
}
