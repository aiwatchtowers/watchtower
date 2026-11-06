package cmd

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations/builtin"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// seedRunnableNeedsApproval indexes a runnable needs-approval built-in row
// (Task 8 ships its recipe) and returns its id.
func seedRunnableNeedsApproval(t *testing.T, d *db.DB) int64 {
	t.Helper()
	now := time.Now()
	id, err := d.UpsertBuiltinAutomation(db.Automation{
		BuiltinID: builtin.NeedsApprovalID, Slug: builtin.NeedsApprovalID, Name: "Needs approval",
		TriggerKind: "event", TriggerSpec: `{"type":"approval"}`, OutputsJSON: `["inbox"]`,
		RecipeText: "---\nname: Needs approval\n---\n", ContentHash: "c", ApprovalHash: "h",
	})
	require.NoError(t, err)
	require.NoError(t, d.ConfirmShippedBuiltin(id, "c", "h", now))
	require.NoError(t, d.SetBuiltinEnabled(builtin.NeedsApprovalID, true, now))
	return id
}

func runInboxApprovals(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"inbox", "approvals", "changed"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	inboxApprovalsChangedRef = ""
	return out.String(), err
}

func eventRunCount(t *testing.T, d *db.DB, id int64) int {
	t.Helper()
	runs, err := d.ListAutomationRuns(id, 0)
	require.NoError(t, err)
	n := 0
	for _, r := range runs {
		if r.Trigger == db.TriggerEvent && r.Status == db.RunQueued {
			n++
		}
	}
	return n
}

// With no daemon running the run is queued and the command exits 0,
// printing nothing.
func TestInboxApprovalsChanged_QueuesWithoutADaemon(t *testing.T) {
	d := writeActionsConfig(t)
	id := seedRunnableNeedsApproval(t, d)
	for _, ref := range []string{"action:7", "reminder:7"} {
		out, err := runInboxApprovals(t, "--ref", ref)
		require.NoError(t, err, ref)
		assert.Empty(t, out, ref)
	}
	assert.Equal(t, 1, eventRunCount(t, d, id), "both refs merged into one queued run")
}

func TestInboxApprovalsChanged_MalformedRefRefused(t *testing.T) {
	d := writeActionsConfig(t)
	id := seedRunnableNeedsApproval(t, d)
	for _, ref := range []string{"x:7", "action:", "action:-1", ""} {
		_, err := runInboxApprovals(t, "--ref", ref)
		require.Error(t, err, ref)
		assert.Contains(t, err.Error(), "action:<id> or reminder:<id>", ref)
	}
	assert.Zero(t, eventRunCount(t, d, id))
}

func TestInboxApprovalsChanged_IsHidden(t *testing.T) {
	assert.True(t, inboxApprovalsCmd.Hidden)
}

// buildToolRegistry installs the hook once; a hook already on the handle
// (the daemon's) is kept.
func TestBuildToolRegistry_InstallsApprovalHook(t *testing.T) {
	d := writeActionsConfig(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	id := seedRunnableNeedsApproval(t, d)
	require.False(t, d.HasApprovalHook())
	buildToolRegistry(cfg, d)
	require.True(t, d.HasApprovalHook())
	_, err = d.InsertReminder(db.Reminder{Note: "ping acme", RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err)
	assert.Equal(t, 1, eventRunCount(t, d, id))

	called := false
	d.SetApprovalHook(func(string) { called = true })
	buildToolRegistry(cfg, d)
	_, err = d.InsertReminder(db.Reminder{RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err)
	assert.True(t, called, "an existing hook is kept")
}

func TestApprovalHook_WakeErrorLogged(t *testing.T) {
	d := writeActionsConfig(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	id := seedRunnableNeedsApproval(t, d)
	// A pid file that cannot be read makes wakeAutomations fail.
	require.NoError(t, os.MkdirAll(pidFilePath(cfg), 0o700))
	var lines []string
	orig := approvalHookLogf
	approvalHookLogf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	t.Cleanup(func() { approvalHookLogf = orig })

	installApprovalHook(cfg, d)
	rem, err := d.InsertReminder(db.Reminder{Note: "ping acme", RemindAt: "2000-01-01T00:00:00Z"})
	require.NoError(t, err, "the writer's result is unchanged")
	require.NotZero(t, rem)
	assert.Equal(t, 1, eventRunCount(t, d, id), "the run is queued before the wake")
	require.Len(t, lines, 1)
	assert.Contains(t, lines[0], "approval hook: waking the daemon: ")
	assert.NotContains(t, lines[0], "ping acme")
}

// A running daemon that cannot be woken is not an error (wakeNote's rule);
// another wake error is logged.
func TestApprovalHook_DaemonThatCannotWakeIsNotLogged(t *testing.T) {
	writeActionsConfig(t)
	cfg, err := workspaceConfigFromFlags()
	require.NoError(t, err)
	var lines []string
	origLog, origWake := approvalHookLogf, approvalWakeAutomations
	approvalHookLogf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	t.Cleanup(func() { approvalHookLogf, approvalWakeAutomations = origLog, origWake })

	approvalWakeAutomations = func(*config.Config) (bool, error) { return false, errDaemonCannotWake }
	approvalWake(cfg)()
	assert.Empty(t, lines)

	approvalWakeAutomations = func(*config.Config) (bool, error) { return false, errors.New("boom") }
	approvalWake(cfg)()
	assert.Equal(t, []string{"approval hook: waking the daemon: boom"}, lines)
}
