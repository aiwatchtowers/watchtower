package cmd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
)

// seedLegacyInstall lays out what `integrate claude-code --project N` wrote
// before the Workbench rename (spec 2026-10-02 §5.1): the marked
// watchtower-project skill with its shipped-digest sidecar, the old hook
// commands, two allow rules naming the old server, and the old local
// registration.
func seedLegacyInstall(t *testing.T, f *fakeWorkbenchClaude, folder string, id int64) {
	t.Helper()
	skillDir := filepath.Join(folder, ".claude", "skills", devpack.LegacySkillName)
	require.NoError(t, os.MkdirAll(skillDir, 0o755))
	skill := "---\nname: watchtower-project\ndescription: old\n" + devpack.MarkerKey + ": v1\n---\n\nOld.\n"
	require.NoError(t, os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte(skill), 0o644))
	sum := sha256.Sum256([]byte(skill))
	require.NoError(t, os.WriteFile(filepath.Join(skillDir, ".watchtower-shipped"), []byte(hex.EncodeToString(sum[:])+"\n"), 0o644))
	n := strconv.FormatInt(id, 10)
	settings := `{"permissions": {"allow": ["mcp__watchtower-project__update_target", "mcp__watchtower-project__project_board"]},
 "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/local/bin/watchtower project brief --project ` + n + `", "timeout": 10}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/watchtower project check --project ` + n + ` --stop-hook", "timeout": 15}]}]}}`
	require.NoError(t, os.WriteFile(filepath.Join(folder, ".claude", "settings.local.json"), []byte(settings), 0o644))
	f.registered[fakeRegistration(folder, devpack.LegacyMCPServerName)] = true
}

func statusJSON(t *testing.T, p *db.Workbench) workbenchStatusJSON {
	t.Helper()
	var out bytes.Buffer
	require.NoError(t, runWorkbenchStatus(context.Background(), &out, p, true))
	var got workbenchStatusJSON
	require.NoError(t, json.Unmarshal(out.Bytes(), &got), out.String())
	var raw map[string]any
	require.NoError(t, json.Unmarshal(out.Bytes(), &raw))
	for _, key := range []string{"legacy", "legacy_skill", "project_id", "hook", "mcp", "current_mcp"} {
		assert.Contains(t, raw, key, "integrate status --json carries %q", key)
	}
	return got
}

// integrate status --json: a never-resynced folder reports legacy, and its
// old hook and registration still count as installed; after the resync
// legacy is false.
func TestIntegrateWorkbenchStatusJSON_ReportsALegacyFolder(t *testing.T) {
	f := useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	seedLegacyInstall(t, f, p.FolderPath, p.ID)

	got := statusJSON(t, p)
	assert.True(t, got.Legacy)
	assert.True(t, got.Hook && got.StopHook && got.MCP, "%+v", got)
	assert.Equal(t, "unchanged", got.LegacySkill)
	assert.Equal(t, "missing", got.Skill)

	var out bytes.Buffer
	require.NoError(t, runWorkbenchInstall(context.Background(), &out, p))
	assert.Contains(t, out.String(), "legacy   removed the old watchtower-project skill")
	assert.Contains(t, out.String(), "2 permission rule(s) in .claude/settings.local.json still name the old watchtower-project server")

	got = statusJSON(t, p)
	assert.False(t, got.Legacy)
	assert.Equal(t, "", got.LegacySkill)
	assert.True(t, got.Hook && got.StopHook && got.MCP, "%+v", got)
	assert.False(t, f.registered[fakeRegistration(p.FolderPath, devpack.LegacyMCPServerName)])
}

// workbench resync --json reports the migration in its additive legacy_*
// fields and suggests re-allowing the old server's tools.
func TestWorkbenchResyncJSON_ReportsTheLegacyMigration(t *testing.T) {
	f := useFakeWorkbenchClaude(t)
	database := writeActionsConfig(t)
	folder := resyncFolder(t)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	seedLegacyInstall(t, f, folder, pid)

	out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	var raw map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &raw))
	for _, key := range []string{"legacy_skill", "legacy_mcp_removed", "legacy_hooks_replaced", "legacy_permission_rules"} {
		assert.Contains(t, raw, key)
	}
	res := decodeResync(t, out)
	assert.True(t, res.IntegrationOK, res.IntegrationError)
	assert.Equal(t, "removed", res.LegacySkill)
	assert.True(t, res.LegacyMCPRemoved)
	assert.True(t, res.LegacyHooksReplaced)
	assert.Equal(t, 2, res.LegacyPermissionRules)
	assert.Contains(t, res.Suggestions,
		"2 permission rule(s) in .claude/settings.local.json still name the old watchtower-project server; re-allow the tools under watchtower-workbench when Claude Code asks.")

	// A second resync finds nothing legacy left.
	out, _, err = runResync(t, strconv.FormatInt(pid, 10), "--json")
	require.NoError(t, err)
	res = decodeResync(t, out)
	assert.Equal(t, "", res.LegacySkill)
	assert.False(t, res.LegacyMCPRemoved || res.LegacyHooksReplaced)
	assert.Equal(t, 2, res.LegacyPermissionRules, "the owner's rules are reported, never rewritten")
}

// When both unregistrations fail, the removal names each registration that
// survived — the current one is not hidden behind the legacy one.
func TestIntegrateWorkbenchRemove_NamesEverySurvivingRegistration(t *testing.T) {
	f := useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	f.registered[fakeRegistration(p.FolderPath, devpack.WorkbenchMCPServerName)] = true
	f.registered[fakeRegistration(p.FolderPath, devpack.LegacyMCPServerName)] = true
	f.failRemove = true

	var out bytes.Buffer
	err := runWorkbenchRemove(context.Background(), &out, p)
	require.Error(t, err, "failed unregistrations are reported")
	assert.Contains(t, out.String(), "still registered: "+devpack.WorkbenchMCPServerName+"\n")
	assert.Contains(t, out.String(), "still registered: "+devpack.LegacyMCPServerName+"\n")
	assert.NotContains(t, out.String(), "Nothing left installed.")
}

// A resync whose `mcp add` failed leaves a legacy folder entirely on its old
// setup (old skill, hooks and registration): mcp and hook still read true
// (the session keeps working), current_mcp says the new registration is
// missing. A later install that registers it migrates the folder.
func TestIntegrateWorkbenchStatusJSON_ReportsTheCurrentRegistration(t *testing.T) {
	f := useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	seedLegacyInstall(t, f, p.FolderPath, p.ID)
	assert.False(t, statusJSON(t, p).CurrentMCP)

	f.failAdd = true
	var out bytes.Buffer
	assert.Error(t, runWorkbenchInstall(context.Background(), &out, p))
	got := statusJSON(t, p)
	assert.Equal(t, "missing", got.Skill, "the new skill is not installed over an old registration")
	assert.Equal(t, "unchanged", got.LegacySkill, "the old skill is kept")
	assert.True(t, got.Hook && got.StopHook, "the old hooks are kept: %+v", got)
	assert.True(t, got.MCP, "the old registration still serves the folder")
	assert.False(t, got.CurrentMCP)
	assert.True(t, got.Legacy)

	f.failAdd = false
	out.Reset()
	require.NoError(t, runWorkbenchInstall(context.Background(), &out, p))
	got = statusJSON(t, p)
	assert.True(t, got.MCP && got.CurrentMCP, "%+v", got)
	assert.False(t, got.Legacy)
}

// The resync's suggestions name the skill and tools the folder's session
// actually has: the new ones once the new server is registered, the old ones
// when a pre-rename folder was left on its old setup, and no tool at all
// when no server of ours is known to serve the folder.
func TestWorkbenchResync_SuggestionsMatchTheRegisteredVocabulary(t *testing.T) {
	sourcesLine := func(t *testing.T, res workbenchResyncJSON) string {
		t.Helper()
		for _, s := range res.Suggestions {
			if strings.Contains(s, "no sources") {
				return s
			}
		}
		t.Fatalf("no sources suggestion in %q", res.Suggestions)
		return ""
	}
	resync := func(t *testing.T, legacy bool, failAdd bool) workbenchResyncJSON {
		t.Helper()
		f := useFakeWorkbenchClaude(t)
		database := writeActionsConfig(t)
		folder := resyncFolder(t)
		pid, err := database.CreateWorkbench("acme", folder)
		require.NoError(t, err)
		if legacy {
			seedLegacyInstall(t, f, folder, pid)
		}
		f.failAdd = failAdd
		out, _, err := runResync(t, strconv.FormatInt(pid, 10), "--json")
		require.NoError(t, err)
		return decodeResync(t, out)
	}

	t.Run("registered", func(t *testing.T) {
		res := resync(t, true, false)
		assert.Contains(t, sourcesLine(t, res), "(add_workbench_source)")
		assert.Contains(t, strings.Join(res.Suggestions, "\n"), "run the watchtower-workbench skill's setup")
	})
	t.Run("legacy folder kept on its old setup", func(t *testing.T) {
		res := resync(t, true, true)
		require.False(t, res.MCPRegistered)
		assert.Contains(t, sourcesLine(t, res), "(add_project_source)")
		joined := strings.Join(res.Suggestions, "\n")
		assert.Contains(t, joined, "run the watchtower-project skill's setup")
		assert.NotContains(t, joined, "add_workbench_source")
	})
	t.Run("fresh folder without a registration", func(t *testing.T) {
		res := resync(t, false, true)
		require.False(t, res.MCPRegistered)
		line := sourcesLine(t, res)
		assert.NotContains(t, line, "add_workbench_source")
		assert.NotContains(t, line, "add_project_source")
	})
}

// Without the claude CLI the removal cannot see the registrations, so its
// report says so instead of "Nothing left installed."
func TestIntegrateWorkbenchRemove_WithoutClaudeRegistrationsAreUnknown(t *testing.T) {
	p := testWorkbench(t)
	prev := workbenchCommandRunner
	workbenchCommandRunner = func(context.Context, string, string, ...string) ([]byte, error) {
		return nil, fmt.Errorf("exec: claude: %w", exec.ErrNotFound)
	}
	t.Cleanup(func() { workbenchCommandRunner = prev })

	var out bytes.Buffer
	require.Error(t, runWorkbenchRemove(context.Background(), &out, p), "the manual unregistration is reported")
	assert.Contains(t, out.String(), "MCP registrations: unknown (claude CLI not found)")
	assert.NotContains(t, out.String(), "Nothing left installed.")
}

// A leftovers check that fails is reported, not swallowed.
func TestIntegrateWorkbenchRemove_ReportsAFailedLeftoversCheck(t *testing.T) {
	useFakeWorkbenchClaude(t)
	p := testWorkbench(t)
	settings := filepath.Join(p.FolderPath, ".claude", "settings.local.json")
	require.NoError(t, os.MkdirAll(filepath.Dir(settings), 0o755))
	require.NoError(t, os.WriteFile(settings, []byte(`{"hooks": [`), 0o644))

	var out bytes.Buffer
	require.Error(t, runWorkbenchRemove(context.Background(), &out, p))
	assert.Contains(t, out.String(), "Could not check what is left installed:")
	assert.NotContains(t, out.String(), "Nothing left installed.")
}
