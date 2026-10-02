package cmd

import (
	"bytes"
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
		assert.Equal(t, "error", conn.Status, "an unmounted connection is surfaced on its row")
		assert.Contains(t, conn.Error, "connections tools")
		assert.NotEmpty(t, conn.ToolsListFailedAt)

		// The next launch backs off instead of paying the timeout again.
		calls := stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}}, nil)
		assert.Empty(t, loadExternalMCPServers(cfg, cfg.DBPath()))
		assert.Empty(t, *calls, "a recent failure is not retried at launch")
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
		conn, err := database.GetExternalConnection(id)
		require.NoError(t, err)
		assert.Equal(t, "error", conn.Status)
		assert.Contains(t, conn.Error, "read-only")
	})
	t.Run("oauth row with no read-only tool is not left ok", func(t *testing.T) {
		cfg := writeConnectionsConfig(t)
		database, err := db.Open(cfg.DBPath())
		require.NoError(t, err)
		t.Cleanup(func() { _ = database.Close() })
		server, _ := newFakeTokenServer(t, false)
		id, _ := setupOAuthConnection(t, database, cfg, server.URL, time.Now().Add(time.Hour))
		require.NoError(t, database.SetExternalConnectionTools(id,
			[]db.ExternalTool{{Name: "createIssue"}}, time.Now().UTC().Format(time.RFC3339)))

		assert.Empty(t, loadExternalMCPServers(cfg, cfg.DBPath()))
		conn, err := database.GetExternalConnection(id)
		require.NoError(t, err)
		assert.Equal(t, "error", conn.Status)
	})
}

// TestQC02_OneConnectionFailingLeavesOthersMounted: a connection whose
// listing fails is skipped alone.
func TestQC02_OneConnectionFailingLeavesOthersMounted(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	insertStaticConnection(t, database, cfg) // never listed; its listing fails
	otherID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "other", Kind: "http", URL: "https://example.com/other", Enabled: true,
	})
	require.NoError(t, err)
	cacheReadOnlyTool(t, database, otherID)
	stubToolsList(t, nil, errors.New("connection refused"))

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, "other", servers[0].Name)
}

// TestQC02_ListingUsesTheOAuthBearer: an OAuth connection is listed with the
// freshly verified bearer, never the raw secret.
func TestQC02_ListingUsesTheOAuthBearer(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	server, _ := newFakeTokenServer(t, false)
	id, _ := setupOAuthConnection(t, database, cfg, server.URL, time.Now().Add(time.Hour))
	_, err = database.Exec(`DELETE FROM external_connection_tools WHERE connection_id = ?`, id)
	require.NoError(t, err)
	calls := stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}}, nil)

	require.Len(t, loadExternalMCPServers(cfg, cfg.DBPath()), 1)
	require.Len(t, *calls, 1)
	assert.Equal(t, "Bearer access-token-1", (*calls)[0].Headers["Authorization"])
}

// TestQC02_OwnerAllowListOverridesDefault: the owner's explicit list is
// allowed as given for tools the server does not mark as writes — but only
// once the tools are listed (a never-listed connection is listed first).
func TestQC02_OwnerAllowListOverridesDefault(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	calls := stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}, {Name: "createIssue"}}, nil)
	require.NoError(t, database.SetExternalConnectionAllowTools(id, []string{"createIssue"}))

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, []string{"createIssue"}, servers[0].AllowTools)
	assert.Equal(t, []string{"getIssue"}, servers[0].DenyTools)
	assert.Len(t, *calls, 1, "an explicit list still needs a listing to rule out writes")
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
	assert.Contains(t, out, "1 of 2 tools available to the chat (read-only tools only)")
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

	_, err = runConnections(t, "", "tools", idArg, "--allow", "getIssue,")
	require.ErrorContains(t, err, "empty tool name")
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Nil(t, conn.AllowTools, "a rejected --allow changes nothing")

	_, err = runConnections(t, "", "tools", idArg, "--allow", " getIssue , nope")
	require.ErrorContains(t, err, `"nope" is not in the server's last tool list`,
		"an unlisted name could be a write the listing never saw")
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Nil(t, conn.AllowTools)

	_, err = runConnections(t, "", "tools", idArg, "--allow", " getIssue ")
	require.NoError(t, err)
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, []string{"getIssue"}, conn.AllowTools, "names are trimmed")
}

// TestQC02_EnableWithAFailedRelistingKeepsTheLastListing: re-enabling a
// connection whose earlier listing succeeded but whose new one fails mounts
// from the last good listing (the same cache a chat launch uses), never from
// names the listing lacks.
func TestQC02_EnableWithAFailedRelistingKeepsTheLastListing(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	require.NoError(t, database.SetExternalConnectionTools(id,
		[]db.ExternalTool{{Name: "getIssue"}, {Name: "createIssue"}}, time.Now().UTC().Format(time.RFC3339)))
	require.NoError(t, database.SetExternalConnectionEnabled(id, false))
	stubToolsList(t, nil, errors.New("connection refused"))

	stdout, stderr, err := runConnectionsSplit(t, "", "enable", strconv.FormatInt(id, 10))
	require.NoError(t, err)
	assert.Contains(t, stderr, "still applies")
	assert.Contains(t, stdout, "1 of 2 tools available")
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", conn.Status)
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
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "error", conn.Status, "the Desktop ignores exit-0 output, so the row says it")

	stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}, {Name: "createIssue"}}, nil)
	stdout, _, err = runConnectionsSplit(t, "", "enable", idArg)
	require.NoError(t, err)
	assert.Contains(t, stdout, "1 of 2 tools available to the chat")
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", conn.Status)
}

// TestQC02_EnableKeepsACredentialStatus: enabling an OAuth connection whose
// grant is dead leaves the row as QC-04 recorded it ("revoked") — the tool
// policy neither overwrites it with a tools error nor, with an explicit
// list, flips it to ok.
func TestQC02_EnableKeepsACredentialStatus(t *testing.T) {
	for name, allow := range map[string][]string{"default policy": nil, "explicit list": {"getIssue"}} {
		t.Run(name, func(t *testing.T) {
			cfg := writeConnectionsConfig(t)
			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			server, _ := newFakeTokenServer(t, true) // invalid_grant
			id, _ := setupOAuthConnection(t, database, cfg, server.URL, time.Now().Add(30*time.Second))
			require.NoError(t, database.SetExternalConnectionEnabled(id, false))
			if allow != nil {
				require.NoError(t, database.SetExternalConnectionAllowTools(id, allow))
			}
			stubToolsList(t, []db.ExternalTool{{Name: "getIssue"}}, nil)

			_, stderr, err := runConnectionsSplit(t, "", "enable", strconv.FormatInt(id, 10))
			require.NoError(t, err)
			assert.Contains(t, stderr, "no usable credentials")
			conn, err := database.GetExternalConnection(id)
			require.NoError(t, err)
			assert.Equal(t, "revoked", conn.Status)
		})
	}
}

// TestQC02_ToolPolicyChangeReconcilesStatus: following the row's own advice
// (`connections tools <id> --allow …`) clears the tools error; a policy that
// leaves no tool records it.
func TestQC02_ToolPolicyChangeReconcilesStatus(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	idArg := strconv.FormatInt(id, 10)
	require.NoError(t, database.SetExternalConnectionTools(id,
		[]db.ExternalTool{{Name: "createIssue"}}, time.Now().UTC().Format(time.RFC3339)))
	require.Empty(t, loadExternalMCPServers(cfg, cfg.DBPath()))
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.Equal(t, "error", conn.Status)

	_, err = runConnections(t, "", "tools", idArg, "--allow", "createIssue")
	require.NoError(t, err)
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", conn.Status)

	_, err = runConnections(t, "", "tools", idArg, "--default")
	require.NoError(t, err)
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "error", conn.Status)

	// A credential error is never cleared by a tool-policy change.
	require.NoError(t, database.SetExternalConnectionStatus(id, "revoked", "sign in again"))
	_, err = runConnections(t, "", "tools", idArg, "--allow", "createIssue")
	require.NoError(t, err)
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", conn.Status)
}

// TestMarkConnectionOK_KeepsANewerStatus: a launch that read the row as
// "error" does not overwrite a "revoked" a parallel launch recorded since.
func TestMarkConnectionOK_KeepsANewerStatus(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	require.NoError(t, database.SetExternalConnectionStatus(id, "error", "tools: x"))
	snapshot, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	require.NoError(t, database.SetExternalConnectionStatus(id, "revoked", "sign in again"))

	markConnectionOK(database, snapshot)
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", conn.Status)

	markConnectionOK(database, conn)
	conn, err = database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", conn.Status, "with a current snapshot it flips")
}

// TestQC02_AllowNeverAdmitsAnAnnotatedWrite: QC-02 stays read-only — `--allow`
// refuses a tool the server marks as a write, and an allow list set before
// the listing still leaves such a tool out of the chat.
func TestQC02_AllowNeverAdmitsAnAnnotatedWrite(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	idArg := strconv.FormatInt(id, 10)
	tools := []db.ExternalTool{
		{Name: "getIssue", Annotated: true, ReadOnlyHint: true},
		{Name: "createIssue", Annotated: true},
		{Name: "summarize"},
	}

	// Allow list set while the tools were never listed: unchecked for now,
	// and the connection is not mounted until a listing rules on it.
	_, err = runConnections(t, "", "tools", idArg, "--allow", "createIssue,summarize")
	require.NoError(t, err)
	stubToolsList(t, nil, errors.New("connection refused"))
	require.Empty(t, loadExternalMCPServers(cfg, cfg.DBPath()))
	_, err = database.Exec(`UPDATE external_connection_tools SET list_failed_at = '' WHERE connection_id = ?`, id)
	require.NoError(t, err)
	stubToolsList(t, tools, nil)
	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, []string{"summarize"}, servers[0].AllowTools, "the annotated write stays out")
	assert.Contains(t, servers[0].DenyTools, "createIssue")

	// Now listed: naming the write is refused outright, and nothing changes.
	_, err = runConnections(t, "", "tools", idArg, "--allow", "getIssue,createIssue")
	require.ErrorContains(t, err, `"createIssue" is a write tool`)
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, []string{"createIssue", "summarize"}, conn.AllowTools)
}

// TestQC02_AllowRefusesADestructiveTool: owner decision 2026-10-02 — a tool
// the server marks destructiveHint: true is a write even beside readOnlyHint,
// and no --allow unlocks it.
func TestQC02_AllowRefusesADestructiveTool(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	require.NoError(t, database.SetExternalConnectionTools(id, []db.ExternalTool{
		{Name: "getIssue", Annotated: true, ReadOnlyHint: true},
		{Name: "purgeCache", Annotated: true, ReadOnlyHint: true, DestructiveHint: true},
	}, time.Now().UTC().Format(time.RFC3339)))

	_, err = runConnections(t, "", "tools", strconv.FormatInt(id, 10), "--allow", "getIssue,purgeCache")
	require.ErrorContains(t, err, `"purgeCache" is a write tool`)

	servers := loadExternalMCPServers(cfg, cfg.DBPath())
	require.Len(t, servers, 1)
	assert.Equal(t, []string{"getIssue"}, servers[0].AllowTools)
	assert.Equal(t, []string{"purgeCache"}, servers[0].DenyTools)
}

// The Desktop reads `connections tools --json`: an annotated write carries
// write:true (shown without a toggle), the empty states are [] not null, and
// `--allow=` (no names) stores an explicit empty list — every tool off.
func TestConnectionsTools_JSONForTheDesktop(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	id := insertStaticConnection(t, database, cfg)
	idArg := strconv.FormatInt(id, 10)

	out, err := runConnections(t, "", "tools", idArg, "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"tools": []`, "a never-listed connection renders an empty array, not null")

	require.NoError(t, database.SetExternalConnectionTools(id, []db.ExternalTool{
		{Name: "getIssue", Annotated: true, ReadOnlyHint: true},
		{Name: "createIssue", Annotated: true},
		{Name: "runQuery"},
		{Name: "purgeCache", Annotated: true, ReadOnlyHint: true, DestructiveHint: true},
	}, time.Now().UTC().Format(time.RFC3339)))
	out, err = runConnections(t, "", "tools", idArg, "--json")
	require.NoError(t, err, out)
	var wire connectionToolsJSON
	require.NoError(t, json.Unmarshal([]byte(out), &wire))
	assert.Equal(t, []connectionToolJSON{
		{Name: "getIssue", Allowed: true, ReadOnly: true},
		{Name: "createIssue", Write: true},
		{Name: "runQuery"},
		{Name: "purgeCache", Write: true},
	}, wire.Tools)

	// The Desktop passes `--allow=`, which a fresh process parses to an empty,
	// non-nil list. The package-level flag keeps pflag's "changed" state
	// across in-process runs (an empty value then appends to nil), so set the
	// parsed value directly here.
	var buf bytes.Buffer
	connectionsToolsCmd.SetOut(&buf)
	t.Cleanup(func() { connectionsToolsCmd.SetOut(nil) })
	connectionsToolsFlagAllow, connectionsToolsFlagJSON = []string{}, true
	t.Cleanup(resetConnectionsFlags)
	require.NoError(t, runConnectionsTools(connectionsToolsCmd, []string{idArg}))
	out = buf.String()
	wire = connectionToolsJSON{}
	require.NoError(t, json.Unmarshal([]byte(out), &wire))
	assert.True(t, wire.ExplicitSet)
	for _, tool := range wire.Tools {
		assert.False(t, tool.Allowed, tool.Name)
	}
	conn, err := database.GetExternalConnection(id)
	require.NoError(t, err)
	assert.Equal(t, []string{}, conn.AllowTools)
	assert.Equal(t, "error", conn.Status, "no allowed tool: the row says the connection is not mounted")
}
