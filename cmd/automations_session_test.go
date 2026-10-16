package cmd

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// sessionCLIStep seeds a workbench run waiting for the app with one open
// session step and a session row of that run; it returns the step and the
// session ids.
func sessionCLIStep(t *testing.T, c *autoCLI) (runID, stepID, sessionID int64) {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	wb, err := c.d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	a := automationstest.SeedAutomation(t, c.d, autoCLIRecipeText(`return 1`),
		automationstest.SeedOptions{Slug: "review", Scope: automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: wb}})
	runID, _, err = c.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: time.Now()})
	require.NoError(t, err)
	ok, err := c.d.ClaimAutomationRun(runID, a.ApprovalHash, a.RecipeText, 50000, 5, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, c.d.SetAutomationRunWaiting(runID, db.WaitApp))
	stepID, err = c.d.AppendAutomationRunStep(db.AutomationRunStep{RunID: runID, Kind: "session", Name: "claude",
		ArgsJSON: `{"prompt":"x","agent":"claude","title":"t"}`, Status: "waiting", StartedAt: time.Now()})
	require.NoError(t, err)
	res, err := c.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, automation_run_id)
		VALUES (?, 'claude', 't', ?, 'uuid', ?)`, wb, folder, runID)
	require.NoError(t, err)
	sessionID, err = res.LastInsertId()
	require.NoError(t, err)
	return runID, stepID, sessionID
}

// countSessionWakes swaps the wake seam for a counter.
func countSessionWakes(t *testing.T) *int {
	t.Helper()
	n := 0
	orig := sessionWake
	sessionWake = func(*config.Config) (bool, error) { n++; return true, nil }
	t.Cleanup(func() { sessionWake = orig })
	return &n
}

func TestAutomationsCLI_SessionLaunchedWakesDaemon(t *testing.T) {
	c := newAutoCLI(t)
	wakes := countSessionWakes(t)
	_, step, sess := sessionCLIStep(t, c)

	out, err := runAutomations(t, "session-launched", "--step", idArg(step), "--session", idArg(sess))
	require.NoError(t, err, out)
	assert.Contains(t, out, "Attached session")
	assert.Equal(t, 1, *wakes, "one wake after the attach")
	got, err := c.d.GetAutomationSessionStep(step)
	require.NoError(t, err)
	assert.Equal(t, sess, got.SessionID)

	// A second attach changes nothing and wakes nobody.
	out, err = runAutomations(t, "session-launched", "--step", idArg(step), "--session", idArg(sess))
	require.NoError(t, err, out)
	assert.Contains(t, out, "nothing attached")
	assert.Equal(t, 1, *wakes)
}

func TestAutomationsCLI_SessionCommandsJSON(t *testing.T) {
	c := newAutoCLI(t)
	wakes := countSessionWakes(t)
	_, step, sess := sessionCLIStep(t, c)

	assert.Equal(t, map[string]any{"attached": true},
		runAutomationsJSON(t, "session-launched", "--step", idArg(step), "--session", idArg(sess)))
	assert.Equal(t, map[string]any{"attached": false},
		runAutomationsJSON(t, "session-launched", "--step", idArg(step), "--session", idArg(sess)))
	assert.Equal(t, map[string]any{"ended": true},
		runAutomationsJSON(t, "session-ended", "--step", idArg(step), "--status", "stopped"))
	assert.Equal(t, map[string]any{"ended": false},
		runAutomationsJSON(t, "session-ended", "--step", idArg(step), "--status", "stopped"))
	assert.Equal(t, 2, *wakes, "a wake per landed report")

	_, step2, _ := sessionCLIStep(t, c)
	assert.Equal(t, map[string]any{"ended": true}, runAutomationsJSON(t, "session-ended", "--step", idArg(step2),
		"--status", "launch_failed", "--error", "Codex was not found"))
	got, err := c.d.GetAutomationSessionStep(step2)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
	assert.Equal(t, "Codex was not found", got.Error)

	for _, args := range [][]string{
		{"session-ended", "--step", idArg(step2), "--status", "later"},
		{"session-ended", "--status", "stopped"},
		{"session-launched", "--step", idArg(step2)},
		{"session-launched", "--session", idArg(sess)},
	} {
		_, err := runAutomations(t, args...)
		assert.Error(t, err, "%v", args)
	}
}

// The Desktop reports what it did; the commands stay open under an agent's
// markers (the run's permissions were confirmed by the owner).
func TestAutomationsCLI_SessionCommandsOpenUnderAgentMarkers(t *testing.T) {
	c := newAutoCLI(t)
	countSessionWakes(t)
	_, step, sess := sessionCLIStep(t, c)
	t.Setenv(automations.RunEnvMarker, "7")
	t.Setenv("CLAUDECODE", "1")
	assert.Equal(t, map[string]any{"attached": true},
		runAutomationsJSON(t, "session-launched", "--step", idArg(step), "--session", idArg(sess)))
	assert.Equal(t, map[string]any{"ended": true},
		runAutomationsJSON(t, "session-ended", "--step", idArg(step), "--status", "stopped"))
}
