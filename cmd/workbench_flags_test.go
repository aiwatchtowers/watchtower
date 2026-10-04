package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/workbenchcheck"
)

// The Workbench rename (spec 2026-10-02 §4.2, §5.2): `workbench` is the
// command, `project` its hidden alias; --workbench the flag, --project its
// hidden alias, whose use selects the pre-rename vocabulary.

// runRootCmd runs rootCmd with args and resets every flag the run set on cmds
// afterwards (rootCmd is shared across tests).
func runRootCmd(t *testing.T, cmds []*cobra.Command, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(args)
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	resetSetFlags(append(cmds, rootCmd)...)
	return out.String(), errOut.String(), err
}

func TestWorkbench_CreateJSONIsTheSameUnderTheProjectAlias(t *testing.T) {
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(folder, "README.md"), []byte("# Acme\n"), 0o644))

	outputs := map[string]string{}
	for _, name := range []string{"project", "workbench"} {
		writeActionsConfig(t) // a fresh database each time: the same id
		out, _, err := runWorkbenchAs(t, name, "create", "--folder", folder, "--json")
		require.NoError(t, err, name)
		outputs[name] = out
	}
	var got workbenchCreateJSON
	require.NoError(t, json.Unmarshal([]byte(outputs["workbench"]), &got), outputs["workbench"])
	assert.Equal(t, folder, got.Folder)
	assert.Equal(t, outputs["project"], outputs["workbench"], "the alias runs the same command, JSON keys unchanged")
}

func TestWorkbenchBrief_LegacyFlagGetsTheOldVocabularyAndTheResyncLine(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir()) // no description: setup pending
	require.NoError(t, err)
	id := strconv.FormatInt(pid, 10)

	legacy, _, err := runWorkbenchAs(t, "project", "brief", "--project", id)
	require.NoError(t, err, "a legacy SessionStart hook still exits 0")
	assert.Contains(t, legacy, "Watchtower workbench #"+id)
	assert.Contains(t, legacy, "Setup pending: run the watchtower-project skill's setup (project_info, update_project, first board).")
	assert.Contains(t, legacy, briefLegacyLine)
	assert.NotContains(t, legacy, "watchtower-workbench")

	current, _, err := runWorkbenchAs(t, "workbench", "brief", "--workbench", id)
	require.NoError(t, err)
	assert.Contains(t, current, "Watchtower workbench #"+id)
	assert.Contains(t, current, "Setup pending: run the watchtower-workbench skill's setup (workbench_info, update_workbench, first board).")
	assert.NotContains(t, current, briefLegacyLine)
	assert.NotContains(t, current, "watchtower-project")
	assert.NotContains(t, current, "project_info")
}

// The legacy line goes right after the header when it fits.
func TestRenderWorkbenchBrief_LegacyLineFollowsTheHeader(t *testing.T) {
	p := briefWorkbench()
	out := renderWorkbenchBrief(nil, p, nil, workbenchcheck.Report{}, nil, nil, time.Now(), legacyWorkbenchVocabulary)
	header := briefHeader(p, nil, 0, 0, legacyWorkbenchVocabulary)
	assert.True(t, strings.HasPrefix(out, header+"\n"+briefLegacyLine+"\n"), out)
	assert.Equal(t, 1, strings.Count(out, briefLegacyLine))
}

func TestWorkbenchIDFlags_BothSpellingsAreRefused(t *testing.T) {
	writeActionsConfig(t)

	out, _, err := runWorkbenchAs(t, "workbench", "brief", "--project", "1", "--workbench", "1")
	require.NoError(t, err, "the brief still exits 0")
	assert.Equal(t, "Watchtower: workbench 0 is unavailable: "+errBothWorkbenchFlags.Error()+".\n", out)

	_, _, err = runWorkbenchCheckCmd(t, strings.NewReader(""), "check", "--project", "1", "--workbench", "1", "--json")
	require.ErrorIs(t, err, errBothWorkbenchFlags)

	stdout, stderr, err := runWorkbenchCheckCmd(t, strings.NewReader(`{}`), "check", "--project", "1", "--workbench", "1", "--stop-hook")
	require.NoError(t, err, "the Stop hook still exits 0")
	assert.Empty(t, stdout, "never blocks the stop")
	assert.Contains(t, stderr, errBothWorkbenchFlags.Error())

	integrate := []*cobra.Command{integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd}
	t.Cleanup(func() { integrateWorkbenchID = 0 })
	for _, sub := range []string{"claude-code", "status", "remove"} {
		_, _, err = runRootCmd(t, integrate, "integrate", sub, "--project", "1", "--workbench", "1")
		require.ErrorIs(t, err, errBothWorkbenchFlags, "integrate %s", sub)
	}

	resetMCPFlags(t)
	_, _, err = runRootCmd(t, []*cobra.Command{mcpCmd}, "mcp", "--project", "1", "--workbench", "1")
	require.ErrorIs(t, err, errBothWorkbenchFlags)
}

func TestWorkbenchIDFlags_EitherSpellingSetsTheSameValue(t *testing.T) {
	for _, flag := range []string{"--workbench", "--project"} {
		cmd := &cobra.Command{Use: "x", RunE: func(*cobra.Command, []string) error { return nil }}
		var id int64
		legacy := addWorkbenchIDFlag(cmd, &id, "workbench id")
		cmd.SetArgs([]string{flag, "42"})
		require.NoError(t, cmd.Execute())
		assert.Equal(t, int64(42), id, flag)
		assert.Equal(t, flag == "--project", legacy(), flag)
		assert.True(t, cmd.Flags().Lookup("project").Hidden, "--project stays out of the help")
		assert.False(t, cmd.Flags().Lookup("workbench").Hidden)
	}
}

// PROJ-07 under both spellings: the decision JSON names the skill the
// folder's install has; still once per stop.
func TestWorkbenchCheck_StopHookNamesTheSkillOfTheInvocation(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, _ := driftWorkbench(t, database, folder, "merged")
	id := strconv.FormatInt(pid, 10)
	const input = `{"hook_event_name":"Stop","stop_hook_active":false}`

	for _, tc := range []struct{ command, flag, skill, other string }{
		{"project", "--project", "the watchtower-project skill's", "watchtower-workbench"},
		{"workbench", "--workbench", "the watchtower-workbench skill's", "watchtower-project"},
	} {
		rootCmd.SetIn(strings.NewReader(input))
		out, _, err := runWorkbenchAs(t, tc.command, "check", tc.flag, id, "--stop-hook")
		rootCmd.SetIn(nil)
		workbenchCheckFlagWorkbench, workbenchCheckFlagStopHook = "", false
		require.NoError(t, err, tc.command)
		var got stopHookOutput
		require.NoError(t, json.Unmarshal([]byte(out), &got), "one decision JSON object: %q", out)
		assert.Equal(t, "block", got.Decision)
		assert.Contains(t, got.Reason, tc.skill)
		assert.NotContains(t, got.Reason, tc.other)

		rootCmd.SetIn(strings.NewReader(`{"stop_hook_active":true}`))
		out, _, err = runWorkbenchAs(t, tc.command, "check", tc.flag, id, "--stop-hook")
		rootCmd.SetIn(nil)
		workbenchCheckFlagWorkbench, workbenchCheckFlagStopHook = "", false
		require.NoError(t, err)
		assert.Empty(t, out, "never blocks twice")
	}
}

func TestWorkbench_RootHelpListsWorkbenchNotProject(t *testing.T) {
	out, _, err := runRootCmd(t, []*cobra.Command{rootCmd}, "--help")
	require.NoError(t, err)
	_, commands, ok := strings.Cut(out, "Available Commands:")
	require.True(t, ok, out)
	commands, _, _ = strings.Cut(commands, "\n\n")
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(commands), "\n") {
		names = append(names, strings.Fields(line)[0])
	}
	assert.Contains(t, names, "workbench")
	assert.NotContains(t, names, "project")

	out, _, err = runWorkbenchAs(t, "workbench", "--help")
	require.NoError(t, err)
	assert.Contains(t, out, "Aliases:")
	assert.Contains(t, out, "workbench, project")

	out, _, err = runWorkbenchAs(t, "workbench", "brief", "--help")
	require.NoError(t, err)
	assert.Contains(t, out, "--workbench")
	assert.NotContains(t, out, "--project", "the old flag is hidden")
}
