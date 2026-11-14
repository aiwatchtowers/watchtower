package coach

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The settings destinations (spec part 2, C5) edit one key of a file under a
// temp home; no test here reads or writes the real ~/.claude*.

const ctxSettings = `{
  "enabledPlugins": {
    "alpha@example-market": true,
    "beta@example-market": true
  },
  "model": "opus",
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ]
  }
}
`

// ctxSecret is a fake credential in a server entry: it must never reach a
// row, an error or ClaudeConfig.
const ctxSecret = "Bearer fake-token-0000" // leak-check:allow

var ctxClaudeJSON = `{
  "mcpServers": {
    "alpha-docs": {"type": "http", "url": "https://mcp.example.com/a", "headers": {"Authorization": "` + ctxSecret + `"}},
    "beta-files": {"command": "beta-mcp", "args": ["--stdio"]}
  },
  "numStartups": 5,
  "projects": {
    "/work/acme": {"mcpServers": {"gamma-db": {"command": "gamma"}}, "allowedTools": []}
  }
}
`

func ctxHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	return home
}

func writeHomeFile(t *testing.T, path, s string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, []byte(s), 0o600))
}

func readHomeFile(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	require.NoError(t, err)
	return b
}

func ctxApplier(t *testing.T, d dbs, home string) *Applier {
	t.Helper()
	return &Applier{DB: d.DB, AgentLog: d.al, Home: home, WorkspaceDir: t.TempDir(), Now: func() time.Time { return applyNow }}
}

// proposeCtx files an open context proposal (origin context) for one key.
func proposeCtx(t *testing.T, d dbs, dest, source, before, after string) int64 {
	t.Helper()
	p := db.CoachProposal{Fingerprint: dest + "|" + source + "|" + before, Kind: "cut", Destination: dest,
		SourceKey: source, Title: "title", Why: "why", Metric: "start_tokens", BeforeText: before, AfterText: after}
	id, err := d.InsertContextCoachProposal(p, t0)
	require.NoError(t, err)
	require.NotZero(t, id)
	return id
}

// topKeys decodes a JSON object into its keys, each value compacted.
func topKeys(t *testing.T, raw []byte) map[string]string {
	t.Helper()
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(raw, &m))
	out := map[string]string{}
	for k, v := range m {
		var b bytes.Buffer
		require.NoError(t, json.Compact(&b, v))
		out[k] = b.String()
	}
	return out
}

func TestPluginOff_AppliesWhenOtherKeysChanged(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")

	// Claude Code rewrites the file: another plugin and the permissions change.
	changed := `{"enabledPlugins":{"alpha@example-market":true,"beta@example-market":false},` +
		`"model":"opus","permissions":{"allow":["Bash(ls:*)","Bash(pwd)"]},"theme":"dark"}`
	writeHomeFile(t, path, changed)

	require.NoError(t, ctxApplier(t, d, home).acceptErr(id, ""))
	assert.Equal(t, "accepted", proposal(t, d, id).Status)

	got, want := topKeys(t, readHomeFile(t, path)), topKeys(t, []byte(changed))
	assert.Equal(t, `{"alpha@example-market":false,"beta@example-market":false}`, got["enabledPlugins"])
	delete(got, "enabledPlugins")
	delete(want, "enabledPlugins")
	assert.Equal(t, want, got, "every other key keeps its value")
	assert.Equal(t, "false", proposal(t, d, id).AfterText)
}

func TestPluginOff_StaleWhenOwnKeyChanged(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")

	// The owner uninstalled the plugin: its key is gone.
	gone := `{"enabledPlugins":{"beta@example-market":true}}`
	writeHomeFile(t, path, gone)

	err := ctxApplier(t, d, home).acceptErr(id, "")
	require.ErrorIs(t, err, ErrStale)
	assert.Equal(t, gone, string(readHomeFile(t, path)), "nothing is written")
	assert.Equal(t, "superseded", proposal(t, d, id).Status)
}

func TestPluginOff_VerifiesAfterWrite(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")

	a := ctxApplier(t, d, home)
	// A concurrent writer that read the file before our rename writes its
	// copy back right after it: our key is lost.
	a.afterSettingsWrite = func() { writeHomeFile(t, path, ctxSettings) }

	err := a.acceptErr(id, "")
	require.Error(t, err)
	require.ErrorIs(t, err, errKeyNotHeld)
	assert.NotErrorIs(t, err, ErrStale)
	assert.Equal(t, "open", proposal(t, d, id).Status, "a write that did not hold leaves the card open")
}

func TestPluginOff_RollbackRestoresAbsentKey(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	start := `{"enabledPlugins":{"beta@example-market":true},"model":"opus"}`
	writeHomeFile(t, path, start)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "", "false")

	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))
	assert.Equal(t, `{"alpha@example-market":false,"beta@example-market":true}`,
		topKeys(t, readHomeFile(t, path))["enabledPlugins"])

	_, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Equal(t, topKeys(t, []byte(start)), topKeys(t, readHomeFile(t, path)), "the key is removed again")
	assert.Equal(t, "rolled_back", proposal(t, d, id).Status)
}

func TestPluginOff_RollbackRestoresTrue(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")

	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))
	_, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Equal(t, topKeys(t, []byte(ctxSettings)), topKeys(t, readHomeFile(t, path)))
}

func TestPluginOff_RollbackChangedSince(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")

	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))
	// Turned back on outside Watchtower.
	writeHomeFile(t, path, ctxSettings)
	_, err := a.Rollback(id, false)
	require.ErrorIs(t, err, ErrChangedSince)
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

func TestPluginOff_ProjectInstallsUntouched(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	writeHomeFile(t, claudeSettingsPath(home), ctxSettings)
	installed := filepath.Join(home, ".claude", "plugins", "installed_plugins.json")
	inst := `{"version":2,"plugins":{"alpha@example-market":[{"scope":"user","installPath":"/x"},` +
		`{"scope":"project","projectPath":"/work/acme","installPath":"/y"}]}}`
	writeHomeFile(t, installed, inst)
	project := filepath.Join(t.TempDir(), ".claude", "settings.json")
	projectText := `{"enabledPlugins":{"alpha@example-market":true}}`
	writeHomeFile(t, project, projectText)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")

	require.NoError(t, ctxApplier(t, d, home).acceptErr(id, ""))
	assert.Equal(t, inst, string(readHomeFile(t, installed)), "the install records are not touched")
	assert.Equal(t, projectText, string(readHomeFile(t, project)), "a project's own settings are not touched")
}

func TestConnectorsOff_SetsEnvOnly(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	start := `{"enabledPlugins":{"alpha@example-market":true},"env":{"OTHER_FLAG":"1"},"model":"opus"}`
	writeHomeFile(t, path, start)
	id := proposeCtx(t, d, DestConnectorsOff, "connectors", "", `"false"`)

	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))
	got, want := topKeys(t, readHomeFile(t, path)), topKeys(t, []byte(start))
	assert.Equal(t, `{"ENABLE_CLAUDEAI_MCP_SERVERS":"false","OTHER_FLAG":"1"}`, got["env"])
	delete(got, "env")
	delete(want, "env")
	assert.Equal(t, want, got)

	_, err := a.Rollback(id, false)
	require.NoError(t, err)
	assert.Equal(t, topKeys(t, []byte(start)), topKeys(t, readHomeFile(t, path)))
}

func TestConnectorsOff_CreatesEnv(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeSettingsPath(home)
	writeHomeFile(t, path, `{"model":"opus"}`)
	id := proposeCtx(t, d, DestConnectorsOff, "connectors", "", `"false"`)
	require.NoError(t, ctxApplier(t, d, home).acceptErr(id, ""))
	assert.Equal(t, `{"ENABLE_CLAUDEAI_MCP_SERVERS":"false"}`, topKeys(t, readHomeFile(t, path))["env"])
}

func TestMCPServerOff_SavesAndRestoresEntry(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeJSONPath(home)
	writeHomeFile(t, path, ctxClaudeJSON)
	id := proposeCtx(t, d, DestMCPServerOff, "alpha-docs", "present", "")

	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))

	got, want := topKeys(t, readHomeFile(t, path)), topKeys(t, []byte(ctxClaudeJSON))
	servers := topKeys(t, []byte(got["mcpServers"]))
	assert.NotContains(t, servers, "alpha-docs")
	assert.Equal(t, topKeys(t, []byte(want["mcpServers"]))["beta-files"], servers["beta-files"])
	delete(got, "mcpServers")
	delete(want, "mcpServers")
	assert.Equal(t, want, got, "the per-project servers and every other key stay")

	undo := filepath.Join(a.WorkspaceDir, "coach-undo", fmt.Sprintf("%d.json", id))
	fi, err := os.Stat(undo)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
	p := proposal(t, d, id)
	for _, s := range []string{p.BeforeText, p.AfterText, p.Title, p.Why} {
		assert.NotContains(t, s, "fake-token", "the entry stays out of the row")
	}
	assert.Equal(t, "present", p.BeforeText)
	assert.Equal(t, "", p.AfterText)

	_, err = a.Rollback(id, false)
	require.NoError(t, err)
	back := topKeys(t, []byte(topKeys(t, readHomeFile(t, path))["mcpServers"]))
	assert.Equal(t, topKeys(t, []byte(topKeys(t, []byte(ctxClaudeJSON))["mcpServers"])), back, "the same entry is back")
	_, err = os.Stat(undo)
	assert.ErrorIs(t, err, os.ErrNotExist, "the saved entry is removed after Rollback")
}

func TestMCPServerOff_RollbackRefusedWithoutUndoFile(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeJSONPath(home)
	writeHomeFile(t, path, ctxClaudeJSON)
	id := proposeCtx(t, d, DestMCPServerOff, "alpha-docs", "present", "")

	a := ctxApplier(t, d, home)
	require.NoError(t, a.acceptErr(id, ""))
	require.NoError(t, os.Remove(filepath.Join(a.WorkspaceDir, "coach-undo", fmt.Sprintf("%d.json", id))))
	before := readHomeFile(t, path)

	_, err := a.Rollback(id, false)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "saved settings for this server are gone")
	assert.Equal(t, before, readHomeFile(t, path), "nothing is written")
	assert.Equal(t, "accepted", proposal(t, d, id).Status)
}

func TestMCPServerOff_NoWorkspaceRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	path := claudeJSONPath(home)
	writeHomeFile(t, path, ctxClaudeJSON)
	id := proposeCtx(t, d, DestMCPServerOff, "alpha-docs", "present", "")
	a := ctxApplier(t, d, home)
	a.WorkspaceDir = ""
	require.Error(t, a.acceptErr(id, ""))
	assert.Equal(t, ctxClaudeJSON, string(readHomeFile(t, path)))
	assert.Equal(t, "open", proposal(t, d, id).Status)
}

func TestSettings_NotJSONRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	for _, c := range []struct{ dest, source, before, after, path, label string }{
		{DestPluginOff, "alpha@example-market", "true", "false", claudeSettingsPath(home), "settings.json"},
		{DestConnectorsOff, "connectors", "", `"false"`, claudeSettingsPath(home), "settings.json"},
		{DestMCPServerOff, "alpha-docs", "present", "", claudeJSONPath(home), ".claude.json"},
	} {
		writeHomeFile(t, c.path, "not json {")
		id := proposeCtx(t, d, c.dest, c.source, c.before, c.after)
		err := ctxApplier(t, d, home).acceptErr(id, "")
		require.Error(t, err, c.dest)
		assert.Contains(t, err.Error(), c.label, c.dest)
		assert.NotContains(t, err.Error(), home, "%s: the label, never the path", c.dest)
		assert.Equal(t, "not json {", string(readHomeFile(t, c.path)), c.dest)
		assert.Equal(t, "open", proposal(t, d, id).Status, c.dest)
	}
}

func TestSettingsKey_EditedTextRefused(t *testing.T) {
	d := openDBs(t)
	home := ctxHome(t)
	writeHomeFile(t, claudeSettingsPath(home), ctxSettings)
	id := proposeCtx(t, d, DestPluginOff, "alpha@example-market", "true", "false")
	err := ctxApplier(t, d, home).acceptErr(id, "true")
	require.ErrorIs(t, err, ErrInvalidEdit)
	assert.Equal(t, ctxSettings, string(readHomeFile(t, claudeSettingsPath(home))))
}

func TestReadClaudeConfig_NamesOnly(t *testing.T) {
	home := ctxHome(t)
	writeHomeFile(t, claudeSettingsPath(home), `{"enabledPlugins":{"alpha@example-market":true,"beta@example-market":false},`+
		`"env":{"ENABLE_CLAUDEAI_MCP_SERVERS":"false","SECRET_ENV":"fake-env-value"}}`)
	writeHomeFile(t, filepath.Join(home, ".claude", "plugins", "installed_plugins.json"),
		`{"version":2,"plugins":{"alpha@example-market":[{"scope":"user","installPath":"/x"},`+
			`{"scope":"project","projectPath":"/work/acme","installPath":"/y"}],`+
			`"gamma@example-market":[{"scope":"local","projectPath":"/work/other"}]}}`)
	writeHomeFile(t, claudeJSONPath(home), ctxClaudeJSON)

	cfg, err := ReadClaudeConfig(home)
	require.NoError(t, err)
	assert.Equal(t, PluginState{Enabled: true, Scopes: []string{"/work/acme", "user"}}, cfg.Plugins["alpha@example-market"])
	assert.Equal(t, PluginState{Enabled: false}, cfg.Plugins["beta@example-market"])
	assert.Equal(t, PluginState{Scopes: []string{"/work/other"}}, cfg.Plugins["gamma@example-market"])
	assert.Equal(t, []string{"alpha-docs", "beta-files"}, cfg.UserServers)
	assert.Equal(t, map[string][]string{"/work/acme": {"gamma-db"}}, cfg.ProjectServers)
	assert.Equal(t, "false", cfg.ConnectorsEnv)

	dump := fmt.Sprintf("%#v", cfg)
	for _, v := range []string{"fake-token", "fake-env-value", "mcp.example.com", "beta-mcp", "--stdio", "/x", "/y"} {
		assert.NotContains(t, dump, v, "names only")
	}
}

func TestReadClaudeConfig_MissingFilesAreEmpty(t *testing.T) {
	cfg, err := ReadClaudeConfig(t.TempDir())
	require.NoError(t, err)
	assert.Empty(t, cfg.Plugins)
	assert.Empty(t, cfg.UserServers)
	assert.Empty(t, cfg.ProjectServers)
	assert.Equal(t, "", cfg.ConnectorsEnv)
}

func TestReadClaudeConfig_NotJSONNamesTheLabel(t *testing.T) {
	home := ctxHome(t)
	writeHomeFile(t, claudeJSONPath(home), "nope")
	_, err := ReadClaudeConfig(home)
	require.Error(t, err)
	assert.Contains(t, err.Error(), ".claude.json")
	assert.NotContains(t, err.Error(), home)
}

// C1: context proposals take none of the weekly pass's three slots.
func TestWeeklySlots_IgnoreContextProposals(t *testing.T) {
	d := openDBs(t)
	for _, s := range []string{"a@m", "b@m", "c@m", "d@m"} {
		proposeCtx(t, d, DestPluginOff, s, "true", "false")
	}
	proposeCtx(t, d, DestConnectorsOff, "connectors", "", `"false"`)
	open, err := d.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 5)
	assert.Equal(t, 0, weeklyOpen(open))

	gen := &countingGen{out: fixture(t, "propose_slots.json")}
	p := &Proposer{DB: d.DB, Gen: gen, Now: func() time.Time { return sigNow }}
	in := proposeInputs()
	in.Open = open
	n, _, err := p.Run(context.Background(), in)
	require.NoError(t, err)
	assert.Equal(t, 3, n, "five open context proposals leave the weekly pass its 3 slots")
}

// C5: the text key of a settings destination includes its source, so several
// can be open at once; a repo_claude_md context row keeps source_key ”.
func TestKeyOf_SourceKey(t *testing.T) {
	assert.NotEqual(t, keyOf(DestPluginOff, 0, "", "", "a@m"), keyOf(DestPluginOff, 0, "", "", "b@m"))
	assert.Equal(t, keyOf(DestPluginOff, 5, "", "", "a@m"), keyOf(DestPluginOff, 0, "", "", "a@m"), "global")
	assert.Equal(t, keyOf(DestRepoClaudeMD, 5, "", "", ""), keyOf(DestRepoClaudeMD, 5, "", "", "x"),
		"a repository file's key has no source")
	assert.Equal(t, keyOf(DestSession, 0, "", "", ""), keyOf(DestSession, 0, "", "", "x"))
}
