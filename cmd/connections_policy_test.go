package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// TestQC02_PolicyUnmountsDisallowed pins the QC-02 amendment (#608): a
// connection outside AllowedQuickConnections is never mounted (no secret
// read, no listing), while the QC-02 checks still decide the allowed ones.
func TestQC02_PolicyUnmountsDisallowed(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	allowedID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "allowed", Kind: "http", URL: "https://mcp.example.com/a", Enabled: true,
	})
	require.NoError(t, err)
	cacheReadOnlyTool(t, database, allowedID)
	otherID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "other", Kind: "http", URL: "https://other.example.com/mcp", Enabled: true,
	})
	require.NoError(t, err)
	cacheReadOnlyTool(t, database, otherID)
	noToolsID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "no-read-only", Kind: "http", URL: "https://mcp.example.com/b", Enabled: true,
	})
	require.NoError(t, err)
	require.NoError(t, database.SetExternalConnectionTools(noToolsID, []db.ExternalTool{{Name: "createIssue"}}, "2026-10-25T00:00:00Z"))
	calls := stubToolsList(t, nil, errors.New("must not be listed"))

	policytest.Set(t, map[string]any{"AllowedQuickConnections": []any{"https://mcp.example.com"}})
	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, "allowed", servers[0].Name, "QC-02 still unmounts the allowed connection with no read-only tool")
	assert.Empty(t, *calls)
	other, err := database.GetExternalConnection(otherID)
	require.NoError(t, err)
	assert.True(t, other.Enabled, "the row is not rewritten")

	policytest.Set(t, nil)
	assert.Len(t, loadExternalMCPServers(cfg, cfg.DBPath()), 2, "no profile: both pass QC-02")
}

func TestPolicyConnections_AddEnableRefused(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "other", Kind: "http", URL: "https://other.example.com/mcp", Enabled: false,
	})
	require.NoError(t, err)
	policytest.Set(t, map[string]any{"AllowedQuickConnections": []any{"https://mcp.example.com"}})

	_, err = runConnections(t, "", "add", "--name", "new", "--kind", "http", "--url", "https://other.example.com/x")
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Contains(t, err.Error(), "Quick Connection new is not allowed by your organization (allowed: https://mcp.example.com)")
	all, err := database.ListExternalConnections()
	require.NoError(t, err)
	assert.Len(t, all, 1, "no row added")

	_, err = runConnections(t, "", "enable", strconv.FormatInt(id, 10))
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	c, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.False(t, c.Enabled, "row unchanged")

	_, err = runConnections(t, "", "tools", strconv.FormatInt(id, 10), "--refresh")
	require.ErrorIs(t, err, policy.ErrNotAllowed, "a listing would start the server")

	calls := stubToolsList(t, []db.ExternalTool{{Name: "get"}}, nil)
	_, err = runConnections(t, "", "oauth", strconv.FormatInt(id, 10), "--no-open")
	require.ErrorIs(t, err, policy.ErrNotAllowed, "signing in would contact the server")
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.ErrorIs(t, listConnectionTools(cfg, database, &conn), policy.ErrNotAllowed, "every listing path refuses")
	assert.Empty(t, *calls, "no listing reached the server")

	_, err = runConnections(t, "", "disable", strconv.FormatInt(id, 10))
	require.NoError(t, err, "disabling is always allowed")

	err = validateImportCandidate(externalmcp.ImportCandidate{Name: "imported", Kind: "http", URL: "https://other.example.com/x"})
	require.ErrorIs(t, err, policy.ErrNotAllowed, "import marks the candidate as not importable")
}

// TestAutomationMCP_PolicyRefusesBeforeCall: mcp() on a connection the
// policy forbids starts no server and reads no credential.
func TestAutomationMCP_PolicyRefusesBeforeCall(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	_, startFile := insertFakeStdioConnection(t, database, cfg.WorkspaceDir(), "github", true,
		[]db.ExternalTool{{Name: "get_thing", Annotated: true, ReadOnlyHint: true}})
	policytest.Set(t, map[string]any{"AllowedQuickConnections": []any{"/usr/local/bin/acme-mcp"}})

	_, err = newAutomationMCPCaller(cfg, database).Call(context.Background(), "github", "get_thing", json.RawMessage(`{}`))
	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Empty(t, fakeStarts(t, startFile), "no server started")
}
