package cmd

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auditlog"
	"watchtower/internal/automations"
)

func auditEnv(vals map[string]string) func(string) string {
	return func(k string) string { return vals[k] }
}

func TestCLIAudit_OnlyUnderMarker(t *testing.T) {
	_, ok := cliAuditEvent("kb search", auditEnv(nil), nil)
	assert.False(t, ok, "the owner's own CLI writes no line")

	e, ok := cliAuditEvent("kb search", auditEnv(map[string]string{terminalSessionEnv: "42"}), nil)
	require.True(t, ok)
	assert.Equal(t, "terminal:42", e.Session)
	assert.Equal(t, "cli", e.Surface)
	line := auditlog.Line(e)
	assert.Contains(t, line, `"proc":"cli:kb/search"`, "the path survives the line's sanitising")
	assert.Contains(t, line, `"tool":"kb/search"`)
	assert.Equal(t, "ok", e.Result)
	assert.Zero(t, e.Rows)
	assert.Zero(t, e.Bytes)
	assert.Empty(t, e.Filters)

	e, ok = cliAuditEvent("digest", auditEnv(map[string]string{automations.RunEnvMarker: "9"}), nil)
	require.True(t, ok)
	assert.Equal(t, "run:9", e.Session)
}

func TestCLIAudit_OnlyContentCommands(t *testing.T) {
	env := auditEnv(map[string]string{terminalSessionEnv: "42"})
	for _, path := range []string{"config set", "gmail status", "workbench board", ""} {
		_, ok := cliAuditEvent(path, env, nil)
		assert.False(t, ok, path)
	}
}

func TestCLIAudit_ErrorResult(t *testing.T) {
	e, ok := cliAuditEvent("memory recall", auditEnv(map[string]string{terminalSessionEnv: "42"}), errors.New("boom"))
	require.True(t, ok)
	assert.Equal(t, "error", e.Result)
}

func TestCLIAudit_ListedPathsExist(t *testing.T) {
	for path := range cliContentCommands {
		args := strings.Fields(path)
		c, rest, err := rootCmd.Find(args)
		require.NoError(t, err, path)
		assert.Empty(t, rest, path)
		assert.Equal(t, path, strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name())), path)
	}
}

// cliExcludedCommands are commands that print something but deliberately
// write no CLI audit line, each with the reason.
var cliExcludedCommands = map[string]string{
	"meeting-prep recap":           "recaps notes the caller passes in, not synced content",
	"meeting-prep transcript save": "saves the caller's own transcript text",
	"linear status":                "workspace and team names and sync state only",
	"linear teams":                 "team names only",
	"confluence spaces":            "space names only",
	"confluence status":            "sync state only",
	"slack accounts":               "workspace names only",
	"code search":                  "the workbench folder's own files, not synced company data",
	"ai query":                     "its tool reads pass the registry gate in its MCP child",
	"workbench session-feed":       "the owner's own agent session dialog",
	"targets note list":            "the owner's own notes",
	"tools call":                   "reads through the registry gate, which budgets and logs each call",
}

func TestCLIAudit_ExcludedCommandsAreDecided(t *testing.T) {
	for path, reason := range cliExcludedCommands {
		assert.NotEmpty(t, reason, path)
		assert.False(t, cliContentCommands[path], "%s is both listed and excluded", path)
		c, rest, err := rootCmd.Find(strings.Fields(path))
		require.NoError(t, err, path)
		assert.Empty(t, rest, path)
		assert.Equal(t, path, strings.TrimSpace(strings.TrimPrefix(c.CommandPath(), rootCmd.Name())), path)
	}
}

// Through the real Execute: only a content command whose Run started writes
// a line — not --help, a usage error or an unknown command.
func TestCLIAudit_ExecuteWritesOnlyWhenTheCommandRan(t *testing.T) {
	probe := &cobra.Command{Use: "zz-audit-probe <q>", Hidden: true, Args: cobra.ExactArgs(1),
		RunE: func(*cobra.Command, []string) error { return nil }}
	rootCmd.AddCommand(probe)
	cliContentCommands["zz-audit-probe"] = true
	t.Cleanup(func() {
		rootCmd.RemoveCommand(probe)
		delete(cliContentCommands, "zz-audit-probe")
		rootCmd.SetArgs(nil)
	})
	var lines []string
	t.Cleanup(auditlog.SetSinkForTest(func(s string) { lines = append(lines, s) }))
	t.Setenv(terminalSessionEnv, "42")
	oldArgs := os.Args
	t.Cleanup(func() { os.Args = oldArgs })

	run := func(args ...string) {
		os.Args = append([]string{"watchtower"}, args...)
		rootCmd.SetArgs(args)
		Execute()
	}
	run("zz-audit-probe")              // usage error: no argument
	run("zz-audit-probe-unknown", "x") // unknown command
	run("zz-audit-probe", "q")
	require.Len(t, lines, 1, "only the run that started writes a line: %v", lines)
	assert.Contains(t, lines[0], `"proc":"cli:zz-audit-probe"`)
	assert.Contains(t, lines[0], `"session":"terminal:42"`)
	assert.Contains(t, lines[0], `"result":"ok"`)

	run("zz-audit-probe", "--help")
	require.NoError(t, probe.Flags().Set("help", "false"))
	assert.Len(t, lines, 1, "--help runs nothing")
}
