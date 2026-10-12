package cmd

import (
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// insertHookRow adds a terminal row of kind to workbench pid (0 = none):
// a codex row before its first SessionStart has no session id.
func insertHookRow(t *testing.T, database *db.DB, pid int64, kind string) int64 {
	t.Helper()
	var project, session any
	if pid > 0 {
		project = pid
	}
	if kind == "claude" {
		session = briefLaunchID
	}
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, ?, 's', '/tmp/acme', ?)`, project, kind, session)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func envOf(rowID string) func(string) string {
	return func(name string) string {
		if name == terminalSessionEnv {
			return rowID
		}
		return ""
	}
}

func rowEnv(id int64) func(string) string { return envOf(strconv.FormatInt(id, 10)) }

func TestResolveCodexHookRow_CodexFromEnv(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	codex := insertHookRow(t, database, pid, "codex")

	row, ok, err := resolveCodexHookRow(database, envOf(" "+strconv.FormatInt(codex, 10)+"\n"))

	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, codex, row.ID)
	assert.Equal(t, pid, row.WorkbenchID.Int64, "the row names the workbench")
	assert.Equal(t, "codex", row.Kind)
	assert.False(t, row.ClaudeSessionID.Valid, "no session id before the first SessionStart")

	row, ok, err = resolveCodexHookRow(database, rowEnv(codex))
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, codex, row.ID)
}

func TestResolveCodexHookRow_NoEnvIsSilentNoop(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	insertHookRow(t, database, pid, "codex")
	for _, raw := range []string{"", "  ", "abc", "-3", "0", "1.5", "99999999999999999999"} {
		row, ok, err := resolveCodexHookRow(database, envOf(raw))
		require.NoError(t, err, "%q", raw)
		assert.False(t, ok, "%q", raw)
		assert.Equal(t, db.TerminalSession{}, row)
	}
}

func TestResolveCodexHookRow_RowOfAnotherKindIsNoop(t *testing.T) {
	database, pid, claude := briefSessionFixture(t)
	shell := insertHookRow(t, database, pid, "shell")
	orphan := insertHookRow(t, database, 0, "codex") // a codex row without a workbench
	for name, id := range map[string]int64{"claude": claude, "shell": shell, "codex without a workbench": orphan} {
		row, ok, err := resolveCodexHookRow(database, rowEnv(id))
		require.NoError(t, err, name)
		assert.False(t, ok, name)
		assert.Equal(t, db.TerminalSession{}, row, name)
	}
}

func TestResolveCodexHookRow_DeletedRowIsNoop(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	codex := insertHookRow(t, database, pid, "codex")
	_, err := database.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, codex)
	require.NoError(t, err)

	row, ok, err := resolveCodexHookRow(database, rowEnv(codex))

	require.NoError(t, err)
	assert.False(t, ok)
	assert.Equal(t, db.TerminalSession{}, row)
}

// codexHookCase is one run of a hook command with --agent codex.
type codexHookCase struct {
	name string
	args []string
}

// codexHookCommands are every hook command a Codex launch passes.
var codexHookCommands = []codexHookCase{
	{"brief", []string{"brief", "--agent", "codex"}},
	{"session-state", []string{"session-state", "--agent", "codex"}},
	{"check", []string{"check", "--agent", "codex", "--stop-hook"}},
	{"ask-guard stop", []string{"ask-guard", "--agent", "codex", "--stop"}},
	{"ask-guard pre-tool-use", []string{"ask-guard", "--agent", "codex", "--pre-tool-use"}},
}

func runCodexHook(t *testing.T, stdin string, args ...string) (stdout, stderr string) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	out, errOut, err := runWorkbenchAs(t, "workbench", args...)
	require.NoError(t, err, "a hook always exits 0")
	return out, errOut
}

// The review focus of spec §6.1: a codex hook whose env names a row of
// another kind, a deleted row or no row writes nothing, prints nothing and
// exits 0, whatever its input.
func TestCodexHook_WithoutItsRowWritesNothing(t *testing.T) {
	database, pid, claude := briefSessionFixture(t)
	deleted := insertHookRow(t, database, pid, "codex")
	_, err := database.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, deleted)
	require.NoError(t, err)
	stop := strings.ReplaceAll(string(codexHookFixture(t, "stop")), codexTUISession, briefLaunchID)
	before := rowSnapshot(t, database, claude)
	for _, env := range []struct{ name, value string }{
		{"another kind", strconv.FormatInt(claude, 10)},
		{"deleted row", strconv.FormatInt(deleted, 10)},
		{"no row", ""},
		{"not a row id", "abc"},
	} {
		for _, hook := range codexHookCommands {
			t.Run(env.name+"/"+hook.name, func(t *testing.T) {
				t.Setenv(terminalSessionEnv, env.value)
				out, errOut := runCodexHook(t, stop, hook.args...)
				assert.Empty(t, out)
				assert.Empty(t, errOut)
				assert.Equal(t, before, rowSnapshot(t, database, claude))
			})
		}
	}
}

// A codex row decodes its events; on a row with no session id yet (spec
// I6) every state, Stop and ask-guard hook writes nothing, and only the
// brief prints.
func TestCodexHook_OnItsRowWithoutAnIDWritesNothing(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	codex := insertHookRow(t, database, pid, "codex")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(codex, 10))
	useAskGuardGen(t, &stubAskGuardGen{reply: verdictJSON("none")})
	before := rowSnapshot(t, database, codex)
	inputs := []string{"", "not json", string(codexHookFixture(t, "stop")), string(codexHookFixture(t, "user_prompt_submit"))}
	for _, hook := range codexHookCommands[1:] {
		for _, in := range inputs {
			out, errOut := runCodexHook(t, in, hook.args...)
			assert.Empty(t, out, hook.name)
			if in == "not json" {
				assert.Equal(t, 1, strings.Count(errOut, "\n"), "%s: one line: %q", hook.name, errOut)
				assert.Contains(t, errOut, "reading the hook input", hook.name)
			} else {
				assert.Empty(t, errOut, "%s %q", hook.name, in)
			}
			assert.Equal(t, before, rowSnapshot(t, database, codex), hook.name)
		}
	}
}

func TestCodexHook_BriefIsTheRowsWorkbench(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	codex := insertHookRow(t, database, pid, "codex")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(codex, 10))
	before := rowSnapshot(t, database, codex)

	out, errOut := runCodexHook(t, string(codexHookFixture(t, "session_start_startup")), "brief", "--agent", "codex")

	assert.Contains(t, out, "Watchtower workbench #"+strconv.FormatInt(pid, 10))
	assert.Contains(t, out, "watchtower-workbench", "the current vocabulary")
	assert.Empty(t, errOut)
	assert.NotEqual(t, before, rowSnapshot(t, database, codex), "the startup stores the session id")
	assert.Equal(t, codexTUISession, storedClaudeSessionID(t, database, codex))
}

// Exactly one of --workbench N and --agent codex: a hook given both, or an
// agent other than codex, prints one stderr line, nothing on stdout, and
// exits 0.
func TestCodexHook_FlagRule(t *testing.T) {
	database, pid, claude := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(claude, 10))
	id := strconv.FormatInt(pid, 10)
	before := rowSnapshot(t, database, claude)
	stop := hookPayload("clear", briefClearedID)
	for _, hook := range codexHookCommands {
		for _, bad := range [][]string{
			append(append([]string{}, hook.args...), "--workbench", id),
			append(append([]string{}, hook.args...), "--project", id),
			replaceArg(hook.args, "codex", "claude"),
			replaceArg(hook.args, "codex", ""),
		} {
			out, errOut := runCodexHook(t, stop, bad...)
			assert.Empty(t, out, "%v", bad)
			assert.Equal(t, 1, strings.Count(errOut, "\n"), "%v: %q", bad, errOut)
			assert.Contains(t, errOut, "--agent", "%v", bad)
		}
	}
	assert.Equal(t, before, rowSnapshot(t, database, claude))
}

// Outside a hook, `workbench check --agent codex` is a plain usage error.
func TestCodexHook_CheckWithoutStopHookIsAnError(t *testing.T) {
	writeActionsConfig(t)
	_, _, err := runWorkbenchAs(t, "workbench", "check", "--agent", "codex")
	assert.ErrorContains(t, err, "--agent codex runs only with --stop-hook")
	_, _, err = runWorkbenchAs(t, "workbench", "check", "--agent", "codex", "--workbench", "1")
	assert.ErrorIs(t, err, errAgentWithWorkbench)
}

func replaceArg(args []string, from, to string) []string {
	out := append([]string{}, args...)
	for i, a := range out {
		if a == from {
			out[i] = to
		}
	}
	return out
}
