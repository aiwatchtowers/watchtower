package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestExternalConnections_CRUD(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{
		Name: "trello", Kind: "stdio", Command: "npx", Args: []string{"-y", "trello-mcp"}, Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.InsertExternalConnection(ExternalConnection{Name: "trello", Kind: "http", URL: "https://x"})
	if err == nil {
		t.Fatal("expected UNIQUE(name) violation")
	}
	en, err := d.ListEnabledExternalConnections()
	if err != nil {
		t.Fatal(err)
	}
	if len(en) != 1 || en[0].Name != "trello" || len(en[0].Args) != 2 {
		t.Fatalf("enabled = %+v", en)
	}
	if err := d.SetExternalConnectionEnabled(id, false); err != nil {
		t.Fatal(err)
	}
	en, _ = d.ListEnabledExternalConnections()
	if len(en) != 0 {
		t.Fatalf("still enabled: %+v", en)
	}
	if err := d.RemoveExternalConnection(id); err != nil {
		t.Fatal(err)
	}
	all, _ := d.ListExternalConnections()
	if len(all) != 0 {
		t.Fatalf("not removed: %+v", all)
	}
}

func TestSetExternalConnectionStatus(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{
		Name: "trello", Kind: "http", URL: "https://x", Enabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SetExternalConnectionStatus(id, "revoked", "invalid_grant"); err != nil {
		t.Fatal(err)
	}
	c, err := d.GetExternalConnection(id)
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != "revoked" || c.Error != "invalid_grant" {
		t.Fatalf("status/error = %q/%q", c.Status, c.Error)
	}
	if err := d.SetExternalConnectionStatus(id, "ok", ""); err != nil {
		t.Fatal(err)
	}
	c, err = d.GetExternalConnection(id)
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != "ok" || c.Error != "" {
		t.Fatalf("status/error not cleared: %q/%q", c.Status, c.Error)
	}
	if err := d.SetExternalConnectionStatus(id+999, "ok", ""); err == nil {
		t.Fatal("expected error for unknown id")
	}
}

// TestExternalConnectionTools_CacheAndAllowList: the QC-02 tool row starts
// absent (never listed, default policy), the tool cache and the owner's allow
// list are set independently, nil clears the allow list back to NULL, and an
// empty listing is still a listing.
func TestExternalConnectionTools_CacheAndAllowList(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{Name: "acme", Kind: "http", URL: "https://x", Enabled: true})
	require.NoError(t, err)
	get := func() ExternalConnection {
		t.Helper()
		c, err := d.GetExternalConnection(id)
		require.NoError(t, err)
		return c
	}

	c := get()
	assert.False(t, c.ToolsListed)
	assert.Nil(t, c.Tools)
	assert.Nil(t, c.AllowTools, "no row = default policy")

	require.NoError(t, d.SetExternalConnectionAllowTools(id, []string{"createIssue"}))
	c = get()
	assert.False(t, c.ToolsListed, "an allow list alone is not a listing")
	assert.Equal(t, []string{"createIssue"}, c.AllowTools)

	tools := []ExternalTool{{Name: "getIssue"}, {Name: "summarize", Annotated: true, ReadOnlyHint: true}}
	require.NoError(t, d.SetExternalConnectionTools(id, tools, "2026-01-02T03:04:05Z"))
	c = get()
	assert.True(t, c.ToolsListed)
	assert.Equal(t, "2026-01-02T03:04:05Z", c.ToolsListedAt)
	assert.Equal(t, tools, c.Tools)
	assert.Equal(t, []string{"createIssue"}, c.AllowTools, "caching tools keeps the allow list")

	require.NoError(t, d.SetExternalConnectionAllowTools(id, nil))
	c = get()
	assert.Nil(t, c.AllowTools)
	assert.True(t, c.ToolsListed, "clearing the allow list keeps the cache")

	require.NoError(t, d.SetExternalConnectionTools(id, nil, "2026-01-02T03:04:06Z"))
	c = get()
	assert.True(t, c.ToolsListed, "an empty listing is still a listing")
	assert.Empty(t, c.Tools)
}

// TestExternalConnectionTools_GoWithTheConnection: removing a connection
// removes its tool row, and caching tools for an unknown id fails.
func TestExternalConnectionTools_GoWithTheConnection(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertExternalConnection(ExternalConnection{Name: "acme", Kind: "http", URL: "https://x"})
	require.NoError(t, err)
	require.NoError(t, d.SetExternalConnectionTools(id, []ExternalTool{{Name: "getIssue"}}, "x"))

	require.NoError(t, d.RemoveExternalConnection(id))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM external_connection_tools`).Scan(&n))
	assert.Zero(t, n, "the tool row must go with its connection")
	assert.Error(t, d.SetExternalConnectionTools(id, nil, "x"), "caching tools for a removed connection must fail")
}
