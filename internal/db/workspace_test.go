package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestUpsertWorkspace(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	ws := Workspace{
		ID:     "T024BE7LD",
		Name:   "my-company",
		Domain: "my-company",
	}
	err = db.UpsertWorkspace(ws)
	require.NoError(t, err)

	got, err := db.GetWorkspace()
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "T024BE7LD", got.ID)
	assert.Equal(t, "my-company", got.Name)
	assert.Equal(t, "my-company", got.Domain)
	assert.NotEmpty(t, got.SyncedAt)
}

func TestUpsertWorkspaceUpdate(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	ws := Workspace{ID: "T001", Name: "old-name", Domain: "old-domain"}
	require.NoError(t, db.UpsertWorkspace(ws))

	ws.Name = "new-name"
	ws.Domain = "new-domain"
	require.NoError(t, db.UpsertWorkspace(ws))

	got, err := db.GetWorkspace()
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "new-name", got.Name)
	assert.Equal(t, "new-domain", got.Domain)
}

func TestGetWorkspaceEmpty(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	got, err := db.GetWorkspace()
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestUpsertWorkspaceSyncedAtUpdated(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	ws := Workspace{ID: "T001", Name: "test", Domain: "test"}
	require.NoError(t, db.UpsertWorkspace(ws))

	first, err := db.GetWorkspace()
	require.NoError(t, err)
	require.NotNil(t, first)
	require.NotEmpty(t, first.SyncedAt)

	// Set synced_at to a known old value to verify upsert updates it
	_, err = db.Exec(`UPDATE workspace SET synced_at = '2020-01-01T00:00:00Z' WHERE id = 'T001'`)
	require.NoError(t, err)

	// Upsert again — synced_at should be updated to now
	require.NoError(t, db.UpsertWorkspace(ws))

	second, err := db.GetWorkspace()
	require.NoError(t, err)
	require.NotNil(t, second)
	assert.NotEqual(t, "2020-01-01T00:00:00Z", second.SyncedAt)
	assert.NotEmpty(t, second.SyncedAt)
}

func TestSecretaryProfileRoundTrip(t *testing.T) {
	db, err := Open(":memory:")
	require.NoError(t, err)
	defer db.Close()

	ws := Workspace{ID: "T024BE7LD", Name: "my-company", Domain: "my-company"}
	if err := db.UpsertWorkspace(ws); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetSecretaryProfile()
	if err != nil || got != "" {
		t.Fatalf("empty profile: got %q, err %v", got, err)
	}
	if err := db.SetSecretaryProfile("I own direction X; anything from the CEO is action"); err != nil {
		t.Fatal(err)
	}
	got, _ = db.GetSecretaryProfile()
	if got != "I own direction X; anything from the CEO is action" {
		t.Fatalf("round trip failed: %q", got)
	}
}
