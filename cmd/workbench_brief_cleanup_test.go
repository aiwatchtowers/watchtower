package cmd

import (
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchcheck"
)

// useCleanupBin pins the binary path the brief names (workbenchExecutable).
func useCleanupBin(t *testing.T, bin string) {
	t.Helper()
	prev := workbenchExecutable
	workbenchExecutable = func() (string, error) { return bin, nil }
	t.Cleanup(func() { workbenchExecutable = prev })
}

// The brief of a known session names the exact cleanup command the
// install's allow rule matches, and how to apply it.
func TestBrief_CleanupLineWhenSessionKnown(t *testing.T) {
	_, pid, row := briefSessionFixture(t)
	useCleanupBin(t, "/tmp/acme bin/watchtower")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	out, errOut := runBriefHook(t, pid, "")
	assert.Empty(t, errOut)
	want := "Cleanup: '/tmp/acme bin/watchtower' workbench cleanup --session " + strconv.FormatInt(row, 10) +
		" (lists what this session would remove; the same command with --apply removes it)"
	assert.Contains(t, out, want)
	assert.Equal(t, 1, strings.Count(out, "Cleanup:"))
	assert.LessOrEqual(t, utf8.RuneCountInString(strings.TrimSuffix(out, "\n")), briefMaxChars)
}

// Without a known session of this workbench — no env var, an invalid one,
// a gone row, a row of another workbench — there is no cleanup line.
func TestBrief_NoCleanupLineWithoutSession(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	useCleanupBin(t, "/usr/local/bin/watchtower")
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 's', '/tmp/other')`, other)
	require.NoError(t, err)
	otherRow, err := res.LastInsertId()
	require.NoError(t, err)

	for _, env := range []string{"", "row-x", "999999", strconv.FormatInt(otherRow, 10)} {
		t.Setenv(terminalSessionEnv, env)
		out, _ := runBriefHook(t, pid, "")
		assert.NotContains(t, out, "Cleanup:", "env %q", env)
		assert.NotContains(t, out, "workbench cleanup", "env %q", env)
	}
}

// The cleanup line's room is set aside like the rules': a full board never
// pushes it out or the body past the cap.
func TestRenderSessionBrief_CleanupLineSurvivesAFullBoard(t *testing.T) {
	long := strings.Repeat("Implement the next part of the plan ", 8)
	var board []db.BoardNode
	for i := 1; i <= 200; i++ {
		board = append(board, briefNode(i, "todo", long))
	}
	const line = "Cleanup: /usr/local/bin/watchtower workbench cleanup --session 3"
	out := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary, briefRules, "", line)
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.True(t, strings.HasSuffix(out, "\n"+line), "the line closes the brief, after the rules")
}
