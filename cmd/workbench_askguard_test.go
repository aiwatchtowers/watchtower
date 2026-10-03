package cmd

import (
	"bytes"
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// askToolDenialJSON is the spec's §6.3 output, verbatim.
const askToolDenialJSON = `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "In a Watchtower workbench, questions to the owner go through ask_owner so they land in the owner's stack — file it there and keep working."}}`

// runAskGuard runs `workbench ask-guard --workbench <raw> --pre-tool-use`
// the way the hook does.
func runAskGuard(t *testing.T, raw string) (stdout, stderr string, err error) {
	t.Helper()
	return runWorkbenchAs(t, "workbench", "ask-guard", "--workbench", raw, "--pre-tool-use")
}

func TestAskGuard_DeniesAskUserQuestionInALiveWorkbench(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)

	out, errOut, err := runAskGuard(t, strconv.FormatInt(id, 10))

	require.NoError(t, err)
	assert.Empty(t, errOut)
	var want bytes.Buffer
	require.NoError(t, json.Compact(&want, []byte(askToolDenialJSON)))
	assert.Equal(t, want.String()+"\n", out)
}

// PROJ-13: the PreToolUse hook never traps a turn — every failure, a
// deleted workbench and a panic print nothing and exit 0, so the tool runs.
func TestProj13_AskGuardFailurePrintsNothingAndExitsZero(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T) string // returns the --workbench value
	}{
		{"deleted workbench", func(t *testing.T) string {
			database := writeActionsConfig(t)
			id, err := database.CreateWorkbench("acme", t.TempDir())
			require.NoError(t, err)
			require.NoError(t, database.DeleteWorkbench(id))
			return strconv.FormatInt(id, 10)
		}},
		{"unknown workbench", func(t *testing.T) string { writeActionsConfig(t); return "424242" }},
		{"bad id", func(t *testing.T) string { writeActionsConfig(t); return "seven" }},
		{"zero id", func(t *testing.T) string { writeActionsConfig(t); return "0" }},
		{"empty id", func(t *testing.T) string { writeActionsConfig(t); return "" }},
		{"broken config", func(t *testing.T) string { writeActionsConfig(t); brokenConfig(t); return "1" }},
		{"panic", func(t *testing.T) string {
			orig := askGuardWorkbenchLive
			askGuardWorkbenchLive = func(string) bool { panic("boom") }
			t.Cleanup(func() { askGuardWorkbenchLive = orig })
			return "1"
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := tc.setup(t)
			out, errOut, err := runAskGuard(t, raw)
			require.NoError(t, err, "PROJ-13: the hook always exits 0")
			assert.Empty(t, out, "PROJ-13: nothing on stdout lets the tool run")
			assert.Empty(t, errOut)
		})
	}
}

// A database another process holds exclusively: the guard gives up within
// its busy timeout and lets the tool run, well inside 2 s.
func TestProj13_AskGuardFinishesFastOnALockedDatabase(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.Exec(`PRAGMA locking_mode=EXCLUSIVE`)
	require.NoError(t, err)
	tx, err := database.Begin()
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback() })
	_, err = tx.Exec(`UPDATE projects SET name = name`)
	require.NoError(t, err)

	start := time.Now()
	out, errOut, err := runAskGuard(t, strconv.FormatInt(id, 10))

	assert.Less(t, time.Since(start), 2*time.Second)
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
}

func TestAskGuard_WithoutThePreToolUseFlagIsAnError(t *testing.T) {
	writeActionsConfig(t)
	out, _, err := runWorkbenchAs(t, "workbench", "ask-guard", "--workbench", "1")
	require.Error(t, err)
	assert.NotContains(t, out, "hookSpecificOutput")
}
