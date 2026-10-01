package cmd

import (
	"encoding/json"
	"errors"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// insertStaticConnection adds an enabled http connection with a static
// header secret and no tool list.
func insertStaticConnection(t *testing.T, database *db.DB, cfg interface{ WorkspaceDir() string }) int64 {
	t.Helper()
	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "acme", Kind: "http", URL: "https://example.com/mcp", Enabled: true,
	})
	require.NoError(t, err)
	require.NoError(t, externalmcp.NewSecretStore(cfg.WorkspaceDir(), id).Save(&externalmcp.Secret{
		Headers: map[string]string{"X-Api-Key": "k"},
	}))
	return id
}

// TestQC02_NeverListedConnectionIsListedOnceAndOnlyReadOnlyToolsMount: a
// connection without a tool list is listed at launch (with its credentials),
// the list is cached, and only its read-only tools are allowed; the next
// launch uses the cache.
func TestQC02_NeverListedConnectionIsListedOnceAndOnlyReadOnlyToolsMount(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	calls := stubToolsList(t, []db.ExternalTool{
		{Name: "getIssue"}, {Name: "createIssue"}, {Name: "summarize", Annotated: true, ReadOnlyHint: true},
	}, nil)

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, []string{"getIssue", "summarize"}, servers[0].AllowTools)
	assert.Equal(t, []string{"createIssue"}, servers[0].DenyTools)
	require.Len(t, *calls, 1)
	assert.Equal(t, "k", (*calls)[0].Headers["X-Api-Key"], "the listing uses the connection's credentials")

	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.True(t, conn.ToolsListed)
	assert.Len(t, conn.Tools, 3)

	require.Len(t, loadExternalMCPServers(cfg, cfg.DBPath()), 1)
	assert.Len(t, *calls, 1, "a cached list is not fetched again at launch")
}

// TestQC02_FailClosed: a connection whose tools cannot be listed, or that has
// no read-only tool, is not mounted at all.
func TestQC02_FailClosed(t *testing.T) {
	t.Run("listing fails", func(t *testing.T) {
		cfg := writeConnectionsConfig(t)
		database, err := db.Open(cfg.DBPath())
		require.NoError(t, err)
		t.Cleanup(func() { _ = database.Close() })
		id := insertStaticConnection(t, database, cfg)
		stubToolsList(t, nil, errors.New("connection refused"))

		assert.Empty(t, loadExternalMCPServers(cfg, cfg.DBPath()))
		conn, err := database.GetExternalConnection(id)
		require.NoError(t, err)
		assert.False(t, conn.ToolsListed, "a failed listing caches nothing")
	})
	t.Run("no read-only tool", func(t *testing.T) {
		cfg := writeConnectionsConfig(t)
		database, err := db.Open(cfg.DBPath())
		require.NoError(t, err)
		t.Cleanup(func() { _ = database.Close() })
		id := insertStaticConnection(t, database, cfg)
		require.NoError(t, database.SetExternalConnectionTools(id,
			[]db.ExternalTool{{Name: "createIssue"}, {Name: "getIssue", Annotated: true}}, time.Now().UTC().Format(time.RFC3339)))

		assert.Empty(t, loadExternalMCPServers(cfg, cfg.DBPath()))
	})
}

// TestQC02_OwnerAllowListOverridesDefault: the owner's explicit list is
// allowed as given — write tools included — even before any listing.
func TestQC02_OwnerAllowListOverridesDefault(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	calls := stubToolsList(t, nil, errors.New("must not be called"))
	require.NoError(t, database.SetExternalConnectionAllowTools(id, []string{"createIssue"}))

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, []string{"createIssue"}, servers[0].AllowTools)
	assert.Empty(t, *calls, "an explicit list needs no listing")
}

func TestConnectionsTools_CommandFlow(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	idArg := strconv.FormatInt(id, 10)
	stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}, {Name: "createIssue"}}, nil)

	out, err := runConnections(t, "", "tools", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "never listed")

	out, err = runConnections(t, "", "tools", idArg, "--refresh")
	require.NoError(t, err, out)
	assert.Contains(t, out, "1 of 2 tools allowed (read-only tools only)")
	assert.Contains(t, out, "allow  getIssue")
	assert.Contains(t, out, "deny   createIssue")

	out, err = runConnections(t, "", "tools", idArg, "--allow", "getIssue,createIssue", "--json")
	require.NoError(t, err, out)
	var wire connectionToolsJSON
	require.NoError(t, json.Unmarshal([]byte(out), &wire))
	assert.True(t, wire.ExplicitSet)
	assert.Equal(t, []connectionToolJSON{
		{Name: "getIssue", Allowed: true, ReadOnly: true},
		{Name: "createIssue", Allowed: true, ReadOnly: false},
	}, wire.Tools)

	out, err = runConnections(t, "", "tools", idArg, "--default")
	require.NoError(t, err, out)
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Nil(t, conn.AllowTools)

	_, err = runConnections(t, "", "tools", idArg, "--default", "--allow", "x")
	require.ErrorContains(t, err, "mutually exclusive")
}

func TestConnectionsEnable_ListsToolsAndReportsFailure(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	require.NoError(t, database.SetExternalConnectionEnabled(id, false))
	idArg := strconv.FormatInt(id, 10)

	stubToolsList(t, nil, errors.New("connection refused"))
	stdout, stderr, err := runConnectionsSplit(t, "", "enable", idArg)
	require.NoError(t, err, "enable succeeds even when the listing fails")
	assert.Contains(t, stdout, "enabled")
	assert.Contains(t, stderr, "none is available to the chat")

	stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}, {Name: "createIssue"}}, nil)
	stdout, _, err = runConnectionsSplit(t, "", "enable", idArg)
	require.NoError(t, err)
	assert.Contains(t, stdout, "1 of 2 tools available to the chat")
}
